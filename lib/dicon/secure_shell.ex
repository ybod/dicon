defmodule Dicon.SecureShell do
  @moduledoc """
  A `Dicon.Executor` based on SSH.

  ## Configuration

  The configuration for this executor must be specified under the configuration
  for the `:dicon` application:

      config :dicon, Dicon.SecureShell,
        dir: "..."

  The available configuration options for this executor are:

    * `:dir` - a binary that specifies the directory where the SSH keys are (in
      the local machine). Defaults to `"~/.ssh"`.

  The username and password user to connect to the server will be picked up by
  the URL that identifies that server (in `:dicon`'s configuration); read more
  about this in the documentation for the `Dicon` module.

  """

  @behaviour Dicon.Executor

  @file_chunk_size 100_000 # in bytes

  defstruct [
    :conn,
    :sftp_channel,
    :connect_timeout,
    :write_timeout,
    :exec_timeout,
  ]

  def connect(authority) do
    config = Application.get_env(:dicon, __MODULE__, [])
    connect_timeout = Keyword.get(config, :connect_timeout, 5_000)
    write_timeout = Keyword.get(config, :write_timeout, 5_000)
    exec_timeout = Keyword.get(config, :exec_timeout, 5_000)
    user_dir = Keyword.get(config, :dir, "~/.ssh") |> Path.expand
    {user, passwd, host, port} = parse_elements(authority)
    opts =
      put_option([], :user, user)
      |> put_option(:password, passwd)
      |> put_option(:user_dir, user_dir)
    host = String.to_charlist(host)

    result =
      with :ok <- ensure_started(),
           {:ok, conn} <- :ssh.connect(host, port, opts, connect_timeout),
           {:ok, sftp_channel} <- :ssh_sftp.start_channel(conn, timeout: connect_timeout) do
        state = %__MODULE__{
          conn: conn,
          sftp_channel: sftp_channel,
          connect_timeout: connect_timeout,
          write_timeout: write_timeout,
          exec_timeout: exec_timeout,
        }
        {:ok, state}
      end

    format_if_error(result)
  end

  defp put_option(opts, _key, nil), do: opts
  defp put_option(opts, key, value) do
    [{key, String.to_charlist(value)} | opts]
  end

  defp ensure_started() do
    case :ssh.start do
      :ok -> :ok
      {:error, {:already_started, :ssh}} -> :ok
      {:error, reason} ->
        {:error, "could not start ssh application: " <>
          Application.format_error(reason)}
    end
  end

  defp parse_elements(authority) do
    parts = String.split(authority, "@", [parts: 2])
    [user_info, host_info] = case parts do
      [host_info] ->
        ["", host_info]
      result -> result
    end

    parts = String.split(user_info, ":", [parts: 2, trim: true])
    destructure([user, passwd], parts)

    parts = String.split(host_info, ":", [parts: 2, trim: true])
    {host, port} = case parts do
      [host, port] ->
        {host, String.to_integer(port)}
      [host] -> {host, 22}
    end

    {user, passwd, host, port}
  end

  def exec(%__MODULE__{} = state, command, device) do
    %{conn: conn, connect_timeout: connect_timeout, exec_timeout: exec_timeout} = state

    result =
      with {:ok, channel} <- :ssh_connection.session_channel(conn, connect_timeout),
           :success <- :ssh_connection.exec(conn, channel, command, exec_timeout),
        do: handle_reply(conn, channel, device, exec_timeout, _acc = [])

    format_if_error(result)
  end

  defp handle_reply(conn, channel, device, exec_timeout, acc) do
    receive do
      {:ssh_cm, ^conn, {:data, ^channel, _code, data}} ->
        handle_reply(conn, channel, device, exec_timeout, [acc | data])
      {:ssh_cm, ^conn, {:eof, ^channel}} ->
        handle_reply(conn, channel, device, exec_timeout, acc)
      {:ssh_cm, ^conn, {:exit_status, ^channel, _status}} ->
        handle_reply(conn, channel, device, exec_timeout, acc)
      {:ssh_cm, ^conn, {:closed, ^channel}} ->
        IO.write(device, acc)
    after
      exec_timeout -> {:error, :timeout}
    end
  end

  def write_file(%__MODULE__{} = state, target, content, :append) do
    %{sftp_channel: channel, connect_timeout: connect_timeout,
      write_timeout: write_timeout, exec_timeout: exec_timeout} = state

    result =
      with {:ok, handle} <- :ssh_sftp.open(channel, target, [:read, :write], connect_timeout),
           {:ok, _} <- :ssh_sftp.position(channel, handle, :eof, exec_timeout),
           :ok <- :ssh_sftp.write(channel, handle, content, write_timeout),
           :ok <- :ssh_sftp.close(channel, handle, exec_timeout),
        do: :ok

    format_if_error(result)
  end

  def write_file(%__MODULE__{} = state, target, content, :write) do
    %{sftp_channel: channel, connect_timeout: connect_timeout,
      write_timeout: write_timeout, exec_timeout: exec_timeout} = state

    result =
      with {:ok, handle} <- :ssh_sftp.open(channel, target, [:write], connect_timeout),
           :ok <- :ssh_sftp.write(channel, handle, content, write_timeout),
           :ok <- :ssh_sftp.close(channel, handle, exec_timeout),
        do: :ok

    format_if_error(result)
  end

  def copy(%__MODULE__{} = state, source, target) do
    %{sftp_channel: channel, connect_timeout: connect_timeout,
      write_timeout: write_timeout, exec_timeout: exec_timeout} = state

    result =
      with {:ok, %File.Stat{size: size}} <- File.stat(source),
           chunk_count = round(Float.ceil(size / @file_chunk_size)),
           stream = File.stream!(source, [], @file_chunk_size) |> Stream.with_index(1),
           {:ok, handle} <- :ssh_sftp.open(channel, target, [:write], connect_timeout),
           Enum.each(stream, fn {chunk, chunk_index} ->
             # TODO: we need to remove this assertion here as well, once we have a
             # better "streaming" API.
             :ok = :ssh_sftp.write(channel, handle, chunk, write_timeout)
             write_progress_bar(chunk_index / chunk_count)
           end),
           IO.puts("\n"),
           :ok <- :ssh_sftp.close(channel, handle, exec_timeout),
        do: :ok

    format_if_error(result)
  end

  defp write_progress_bar(percent) when is_float(percent) and percent >= 0.0 and percent <= 1.0 do
    percent = round(percent * 100)
    done = String.duplicate("═", percent)
    rest = String.duplicate(" ", 100 - percent)
    IO.ANSI.format([:clear_line, ?\r, ?╎, done, rest, ?╎, ?\s, Integer.to_string(percent), ?%])
    |> IO.write
  end

  defp format_if_error(:failure) do
    {:error, "failure on the SSH connection"}
  end

  defp format_if_error({:error, reason} = error) when is_binary(reason) do
    error
  end

  defp format_if_error({:error, reason}) do
    case :inet.format_error(reason) do
      'unknown POSIX error' ->
        {:error, inspect(reason)}
      message ->
        {:error, List.to_string(message)}
    end
  end

  defp format_if_error(non_error) do
    non_error
  end
end
