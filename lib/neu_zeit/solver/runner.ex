defmodule NeuZeit.Solver.Runner do
  @moduledoc false

  @timeout_buffer_ms 15_000
  @shutdown_buffer_ms 1_000

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts) do
    opts =
      opts
      |> Keyword.put_new(:name, __MODULE__)
      |> Keyword.put_new(:max_children, max_concurrency())

    Task.Supervisor.start_link(opts)
  end

  @doc false
  def max_concurrency do
    case Application.get_env(:neu_zeit, :solver_max_concurrency) do
      value when is_integer(value) and value > 0 ->
        value

      nil ->
        solver_workers = NeuZeit.Config.load!().solver.workers
        max(div(System.schedulers_online(), solver_workers), 1)

      value ->
        raise ArgumentError,
              ":neu_zeit, :solver_max_concurrency must be a positive integer, got: #{inspect(value)}"
    end
  end

  def solve(spec, opts \\ []) do
    adapter = Keyword.get(opts, :adapter, Application.get_env(:neu_zeit, :solver_adapter))
    adapter = adapter || NeuZeit.Solver.OrToolsPort
    timeout = Keyword.get(opts, :timeout, timeout_from_spec(spec))
    task_timeout = Keyword.get(opts, :task_timeout, timeout + @shutdown_buffer_ms)
    adapter_opts = Keyword.put(opts, :timeout, timeout)

    task =
      Task.Supervisor.async_nolink(__MODULE__, fn ->
        adapter.solve(spec, adapter_opts)
      end)

    case Task.yield(task, task_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, %{"status" => "EXIT", "error" => inspect(reason)}}
      nil -> timeout_error(task_timeout)
    end
  rescue
    error in RuntimeError ->
      if error.message =~ "maximum number of tasks" do
        {:error, %{"status" => "BUSY", "error" => "solver pool is at capacity, retry later"}}
      else
        reraise error, __STACKTRACE__
      end
  catch
    :exit, reason ->
      {:error, %{"status" => "BUSY", "error" => "solver could not start: #{inspect(reason)}"}}
  end

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

  defp timeout_error(timeout) do
    {:error,
     %{
       "status" => "TIMEOUT",
       "error" => "solver timed out after #{timeout}ms"
     }}
  end
end
