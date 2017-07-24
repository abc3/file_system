require Logger
alias FileSystem.Utils

defmodule FileSystem.Backends.FSInotify do
  @moduledoc """
  This file is a fork from https://github.com/synrc/fs.
  FileSysetm backend for linux and freebsd, a GenServer receive data from Port, parse event
  and send it to the worker process.
  Need `inotify-tools` installed to use this backend.
  """

  use GenServer
  @behaviour FileSystem.Backend
  @sep_char <<1>>

  def bootstrap do
    exec_file = find_executable()
    if is_nil(exec_file) do
      Logger.error "`inotify-tools` is needed to run `file_system` for your system, check https://github.com/rvoicilas/inotify-tools/wiki for more information about how to install it."
      {:error, :fs_inotify_bootstrap_error}
    else
      :ok
    end
  end

  def supported_systems do
    [{:unix, :linux}, {:unix, :freebsd}]
  end

  def known_events do
    [:created, :deleted, :renamed, :closed, :modified, :isdir, :attribute, :undefined]
  end

  defp find_executable do
    System.find_executable("inotifywait")
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, [])
  end

  def init(args) do
    port_path = Utils.format_path(args[:dirs])
    format = ["%w", "%e", "%f"] |> Enum.join(@sep_char) |> to_charlist
    port_args = [
      '-e', 'modify', '-e', 'close_write', '-e', 'moved_to', '-e', 'create',
      '-e', 'delete', '-e', 'attrib', '--format', format, '--quiet', '-m', '-r'
    ] ++ Utils.format_args(args[:listener_extra_args]) ++ port_path
    port = Port.open(
      {:spawn_executable, to_charlist(find_executable())},
      [:stream, :exit_status, {:line, 16384}, {:args, port_args}, {:cd, System.tmp_dir!()}]
    )
    Process.link(port)
    Process.flag(:trap_exit, true)
    {:ok, %{port: port, worker_pid: args[:worker_pid]}}
  end

  def handle_info({port, {:data, {:eol, line}}}, %{port: port}=state) do
    {file_path, events} = line |> parse_line
    send(state.worker_pid, {:backend_file_event, self(), {file_path, events}})
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, _}}, %{port: port}=state) do
    send(state.worker_pid, {:backend_file_event, self(), :stop})
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, port, _reason}, %{port: port}=state) do
    send(state.worker_pid, {:backend_file_event, self(), :stop})
    {:noreply, state}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

  def parse_line(line) do
    {path, flags} =
      case line |> to_string |> String.split(@sep_char, trim: true) do
        [dir, flags, file] -> {Path.join(dir, file), flags}
        [path, flags]      -> {path, flags}
      end
    {path, flags |> String.split(",") |> Enum.map(&convert_flag/1)}
  end

  defp convert_flag("CREATE"),      do: :created
  defp convert_flag("DELETE"),      do: :deleted
  defp convert_flag("ISDIR"),       do: :isdir
  defp convert_flag("MODIFY"),      do: :modified
  defp convert_flag("CLOSE_WRITE"), do: :modified
  defp convert_flag("CLOSE"),       do: :closed
  defp convert_flag("MOVED_TO"),    do: :renamed
  defp convert_flag("ATTRIB"),      do: :attribute
  defp convert_flag(_),             do: :undefined
end
