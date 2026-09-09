defmodule NeuZeit.Solver.PlanRuns do
  @moduledoc """
  Runs calculations outside LiveView processes and reports results through PubSub.

  Navigation does not stop a run. Only one run per plan is allowed. Additional
  requests for that plan are rejected; the solver runner also limits total concurrency.
  """

  use GenServer

  alias NeuZeit.Planning.Solving
  alias Phoenix.PubSub

  @pubsub NeuZeit.PubSub

  # Client

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @doc "Topic carrying this plan's solve events."
  def topic(plan_id), do: "plan:#{plan_id}"

  @doc "Subscribes the calling process to a plan's solve events."
  def subscribe(plan_id), do: PubSub.subscribe(@pubsub, topic(plan_id))

  @doc """
  Starts a solve, unless one is already running for this plan.

  Returns `{:ok, started_at}` or `{:error, :already_running}`.
  """
  def start_solve(plan_id, server \\ __MODULE__),
    do: GenServer.call(server, {:start, plan_id, :async, callers()})

  @doc "Runs through the same coordinator and waits for the full result."
  def solve(plan_id, server \\ __MODULE__),
    do: GenServer.call(server, {:start, plan_id, :wait, callers()}, :infinity)

  defp callers, do: [self() | Process.get(:"$callers", [])]

  @doc "When the current run for this plan began, or nil."
  def started_at(plan_id, server \\ __MODULE__),
    do: GenServer.call(server, {:started_at, plan_id})

  def running?(plan_id, server \\ __MODULE__), do: started_at(plan_id, server) != nil

  @doc "Last run outcome, retained for the latest 100 plans until the server restarts."
  def last_result(plan_id, server \\ __MODULE__),
    do: GenServer.call(server, {:last_result, plan_id})

  # Server

  @impl true
  def init(:ok), do: {:ok, %{runs: %{}, refs: %{}, results: []}}

  @impl true
  def handle_call({:start, plan_id, mode, callers}, from, state) do
    if Map.has_key?(state.runs, plan_id) do
      {:reply, {:error, :already_running}, state}
    else
      started_at = DateTime.utc_now()

      task =
        Task.Supervisor.async_nolink(__MODULE__.Tasks, fn ->
          # Preserve the initiating process chain for ownership-aware resources such as Ecto Sandbox.
          Process.put(:"$callers", callers)
          Solving.solve_plan(plan_id)
        end)

      broadcast(plan_id, {:solve_started, plan_id, started_at})

      state = %{
        state
        | runs:
            Map.put(state.runs, plan_id, %{
              ref: task.ref,
              started_at: started_at,
              waiter: if(mode == :wait, do: from)
            }),
          refs: Map.put(state.refs, task.ref, plan_id),
          results: List.keydelete(state.results, plan_id, 0)
      }

      if mode == :wait, do: {:noreply, state}, else: {:reply, {:ok, started_at}, state}
    end
  end

  def handle_call({:started_at, plan_id}, _from, state) do
    {:reply, get_in(state.runs, [plan_id, :started_at]), state}
  end

  def handle_call({:last_result, plan_id}, _from, state) do
    result =
      case List.keyfind(state.results, plan_id, 0) do
        nil -> nil
        {^plan_id, result} -> result
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state, ref, result)}
  end

  # Report crashed tasks as failures so the UI stops showing calculation progress.
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    {:noreply, finish(state, ref, {:error, %{"status" => "EXIT", "error" => inspect(reason)}})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp finish(state, ref, result) do
    case Map.pop(state.refs, ref) do
      {nil, _refs} ->
        state

      {plan_id, refs} ->
        if waiter = state.runs[plan_id].waiter, do: GenServer.reply(waiter, result)
        broadcast(plan_id, {:solve_finished, plan_id, result})
        # The UI needs the outcome, not a retained copy of every placement.
        summary = if match?({:ok, _}, result), do: {:ok, :complete}, else: result
        results = Enum.take([{plan_id, summary} | state.results], 100)
        %{state | runs: Map.delete(state.runs, plan_id), refs: refs, results: results}
    end
  end

  defp broadcast(plan_id, message), do: PubSub.broadcast(@pubsub, topic(plan_id), message)
end
