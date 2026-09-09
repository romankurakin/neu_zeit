defmodule NeuZeit.Solver.OrToolsPort do
  @behaviour NeuZeit.Solver

  require Logger

  @timeout_buffer_ms 15_000

  @impl true
  def solve(spec, opts \\ []) do
    solver_dir = Keyword.get(opts, :solver_dir, Application.app_dir(:neu_zeit, "priv/solver"))
    script_path = Path.join(solver_dir, "solve.py")
    spec_path = write_spec!(spec)
    timeout = Keyword.get(opts, :timeout, timeout_from_spec(spec))

    args = ["run", "--locked", "--project", solver_dir, "python", script_path, spec_path]

    try do
      case run_command("uv", args, timeout) do
        {:timeout, output} ->
          timeout_error(timeout, output)

        {output, 0} ->
          decode_output(output)

        {output, status} ->
          Logger.error("solver exited with status #{status}: #{output}")

          {:error,
           %{
             "status" => "CRASHED",
             "error" => "solver exited with status #{status}",
             "output" => output
           }}
      end
    after
      File.rm(spec_path)
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp write_spec!(spec) do
    path =
      Path.join(
        System.tmp_dir!(),
        "neu_zeit_solver_#{Ecto.UUID.generate()}.json"
      )

    File.write!(path, Jason.encode!(spec), [:exclusive])
    path
  end

  defp run_command(command, args, timeout) do
    command_path = System.find_executable(command) || raise "#{command} executable not found"

    port =
      Port.open({:spawn_executable, command_path}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :use_stdio,
        args: args
      ])

    collect_output(port, [], deadline(timeout))
  end

  defp collect_output(port, chunks, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect_output(port, [data | chunks], deadline)

      {^port, {:exit_status, status}} ->
        {chunks |> Enum.reverse() |> IO.iodata_to_binary(), status}
    after
      timeout ->
        terminate_port(port)
        {:timeout, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  # Closing the port does not stop uv/python: it reads input from argv.
  # Terminate the process explicitly. Rescue handles a process that exits
  # between the receive timeout and the close call.
  defp terminate_port(port) do
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} -> os_pid
        nil -> nil
      end

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    if os_pid, do: kill_process_tree(os_pid)
  end

  defp kill_process_tree(os_pid) do
    pid = Integer.to_string(os_pid)
    System.cmd("pkill", ["-KILL", "-P", pid], stderr_to_stdout: true)
    System.cmd("kill", ["-KILL", pid], stderr_to_stdout: true)
    :ok
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp timeout_from_spec(spec) do
    spec
    |> solver_time_limit()
    |> case do
      seconds when is_integer(seconds) -> seconds * 1_000 + @timeout_buffer_ms
      seconds when is_float(seconds) -> trunc(seconds * 1_000) + @timeout_buffer_ms
      _ -> 180_000 + @timeout_buffer_ms
    end
  end

  defp solver_time_limit(%{solver: %{time_limit: time_limit}}), do: time_limit
  defp solver_time_limit(%{"solver" => %{"time_limit" => time_limit}}), do: time_limit
  defp solver_time_limit(_spec), do: nil

  defp timeout_error(timeout, output) do
    {:error,
     %{
       "status" => "TIMEOUT",
       "error" => "solver timed out after #{timeout}ms",
       "output" => output
     }}
  end

  def decode_output(output) do
    case Jason.decode(output) do
      {:ok, result} ->
        decoded_result(result)

      {:error, _error} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.reverse()
        |> Enum.find_value(fn line ->
          case Jason.decode(line) do
            {:ok, result} when is_map(result) -> {:ok, result}
            _ -> nil
          end
        end)
        |> case do
          {:ok, result} ->
            decoded_result(result)

          nil ->
            Logger.error("solver produced undecodable output: #{output}")

            {:error,
             %{
               "status" => "PROTOCOL_ERROR",
               "error" => "solver produced invalid JSON",
               "output" => output
             }}
        end
    end
  end

  defp decoded_result(%{"ok" => true} = result), do: {:ok, result}
  defp decoded_result(result), do: {:error, result}
end
