defmodule NeuZeitWeb.SolverCoordinationTest do
  use NeuZeitWeb.ConnCase, async: false
  import NeuZeit.Fixtures
  alias NeuZeit.Solver.PlanRuns

  defmodule GatedSolver do
    @behaviour NeuZeit.Solver
    def solve(_spec, _opts) do
      send(Application.fetch_env!(:neu_zeit, :coordinator_test_owner), {:solver_entered, self()})

      receive do
        :finish -> {:ok, %{"status" => "OPTIMAL", "unplaced" => [], "assignment" => %{}}}
        :crash -> raise "adapter failed"
      after
        5_000 -> raise "test did not release solver"
      end
    end
  end

  setup do
    previous = Application.get_env(:neu_zeit, :solver_adapter)
    Application.put_env(:neu_zeit, :solver_adapter, GatedSolver)
    Application.put_env(:neu_zeit, :coordinator_test_owner, self())

    on_exit(fn ->
      if previous,
        do: Application.put_env(:neu_zeit, :solver_adapter, previous),
        else: Application.delete_env(:neu_zeit, :solver_adapter)

      Application.delete_env(:neu_zeit, :coordinator_test_owner)
    end)

    plan = plan_fixture(term: term_fixture())
    PlanRuns.subscribe(plan.id)
    %{plan: plan}
  end

  test "an API request sees a running UI calculation and returns conflict", %{plan: plan} do
    assert {:ok, _} = PlanRuns.start_solve(plan.id)
    assert_receive {:solver_entered, worker}
    conn = post(build_conn(), ~p"/api/plans/#{plan.id}/solve", %{})
    assert json_response(conn, 409)["detail"] =~ "already running"
    assert PlanRuns.running?(plan.id)
    send(worker, :finish)
    assert_receive {:solve_finished, _, {:ok, _}}, 2_000
  end

  test "API calculation shares progress and completion while retaining its response", %{
    plan: plan
  } do
    request = Task.async(fn -> post(build_conn(), ~p"/api/plans/#{plan.id}/solve", %{}) end)
    assert_receive {:solver_entered, worker}
    assert_receive {:solve_started, _, %DateTime{}}
    assert PlanRuns.running?(plan.id)
    assert {:error, :already_running} = PlanRuns.start_solve(plan.id)
    send(worker, :finish)

    assert %{"data" => %{"status" => "OPTIMAL", "assignment" => %{}}} =
             request |> Task.await() |> json_response(200)

    assert_receive {:solve_finished, _, {:ok, _}}
    refute PlanRuns.running?(plan.id)
    assert PlanRuns.last_result(plan.id) == {:ok, :complete}
  end

  @tag capture_log: true
  test "a failed adapter releases the plan and replies to the waiting API request", %{plan: plan} do
    request = Task.async(fn -> post(build_conn(), ~p"/api/plans/#{plan.id}/solve", %{}) end)
    assert_receive {:solver_entered, worker}
    send(worker, :crash)
    assert request |> Task.await() |> json_response(422)
    assert_receive {:solve_finished, _, {:error, _}}
    refute PlanRuns.running?(plan.id)
  end
end
