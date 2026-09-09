defmodule NeuZeit.Solver.PlanRunsTest do
  use NeuZeit.DataCase, async: false

  alias NeuZeit.{Catalog, Planning}
  alias NeuZeit.Solver.PlanRuns

  setup do
    {:ok, term} =
      Catalog.create_term(%{
        "name" => "Wintersemester 2026/27",
        "starts_on" => "2026-09-07",
        "ends_on" => "2026-12-20"
      })

    {:ok, plan} = Planning.create_plan(%{"term_id" => term.id, "name" => "Entwurf 1"})
    %{term: term, plan: plan}
  end

  test "announces the start and the finish of a run", %{plan: plan} do
    :ok = PlanRuns.subscribe(plan.id)

    assert {:ok, %DateTime{}} = PlanRuns.start_solve(plan.id)
    assert_receive {:solve_started, plan_id, %DateTime{}}, 2_000
    assert plan_id == plan.id

    # An empty term completes quickly. Check that completion is announced.
    assert_receive {:solve_finished, ^plan_id, _result}, 30_000
  end

  test "refuses a second run for the same plan", %{plan: plan} do
    :ok = PlanRuns.subscribe(plan.id)
    assert {:ok, _started} = PlanRuns.start_solve(plan.id)

    assert {:error, :already_running} = PlanRuns.start_solve(plan.id)

    assert_receive {:solve_finished, _plan_id, _result}, 30_000
  end

  test "the plan is free again once the run finishes", %{plan: plan} do
    :ok = PlanRuns.subscribe(plan.id)
    {:ok, _started} = PlanRuns.start_solve(plan.id)
    assert_receive {:solve_finished, _plan_id, _result}, 30_000

    # Give the server a moment to clear its bookkeeping before asking again.
    _ = :sys.get_state(PlanRuns)
    refute PlanRuns.running?(plan.id)
    assert {:ok, _started} = PlanRuns.start_solve(plan.id)
    assert_receive {:solve_finished, _plan_id, _result}, 30_000
  end

  test "a crashing run still reports a finish", %{plan: plan} do
    :ok = PlanRuns.subscribe(plan.id)

    # A plan that no longer exists makes solve_plan raise rather than return.
    {:ok, _} = Planning.delete_plan(Planning.get_plan!(plan.id))

    {:ok, _started} = PlanRuns.start_solve(plan.id)

    assert_receive {:solve_finished, _plan_id, result}, 30_000
    assert {:error, _reason} = result
    assert PlanRuns.last_result(plan.id) == result
  end

  test "a visitor returning after completion can see the last outcome", %{plan: plan} do
    assert PlanRuns.last_result(plan.id) == nil
    :ok = PlanRuns.subscribe(plan.id)
    {:ok, _} = PlanRuns.start_solve(plan.id)
    assert_receive {:solve_finished, _plan_id, result}, 30_000
    expected = if match?({:ok, _}, result), do: {:ok, :complete}, else: result
    assert PlanRuns.last_result(plan.id) == expected
    refute PlanRuns.running?(plan.id)
  end
end
