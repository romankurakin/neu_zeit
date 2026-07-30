defmodule NeuZeit.Solver.RunnerTest do
  use ExUnit.Case, async: false

  alias NeuZeit.Solver.Runner
  alias NeuZeit.TestSupport.HangingSolver

  test "derives safe process concurrency from CP-SAT worker count" do
    expected = max(div(System.schedulers_online(), NeuZeit.Config.load!().solver.workers), 1)
    assert Runner.max_concurrency() == expected
  end

  test "returns BUSY instead of raising when the solver pool is saturated" do
    spec = %{solver: %{time_limit: 30}}
    pool_size = Runner.max_concurrency()

    tasks =
      for _ <- 1..pool_size do
        Task.async(fn ->
          Runner.solve(spec, adapter: HangingSolver, timeout: 5_000, task_timeout: 5_000)
        end)
      end

    try do
      assert wait_for_children(pool_size)

      assert {:error, %{"status" => "BUSY"}} =
               Runner.solve(spec, adapter: HangingSolver, timeout: 1_000, task_timeout: 1_000)
    after
      Runner
      |> Task.Supervisor.children()
      |> Enum.each(&Process.exit(&1, :kill))

      Enum.each(tasks, &Task.await/1)
    end
  end

  defp wait_for_children(count, attempts \\ 200)
  defp wait_for_children(_count, 0), do: false

  defp wait_for_children(count, attempts) do
    if length(Task.Supervisor.children(Runner)) >= count do
      true
    else
      Process.sleep(10)
      wait_for_children(count, attempts - 1)
    end
  end
end
