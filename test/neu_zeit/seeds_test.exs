defmodule NeuZeit.SeedsTest do
  use NeuZeit.DataCase, async: true

  import ExUnit.CaptureIO

  alias NeuZeit.{Catalog, Planning, Repo}

  @seeds Path.expand("../../priv/repo/seeds.exs", __DIR__)

  defp run_seeds, do: capture_io(fn -> Code.eval_file(@seeds) end)

  defp count(schema), do: Repo.aggregate(schema, :count)

  test "fills an empty database once with a plan ready for a calculation" do
    assert run_seeds() =~ "Demonstration data created."

    assert count(Catalog.Course) == 20
    assert count(Catalog.Teacher) == 8
    assert count(Catalog.Cohort) == 4
    assert count(Catalog.Room) == 7
    assert count(Catalog.Workload) == 24
    assert count(Catalog.Session) == 24

    assert [plan] = Repo.all(Planning.Plan)
    assert Planning.check_plan(plan.id) == []
    # The demonstration calculates this plan, so a timetable must exist.
    assert {:ok, _result} = Planning.solve_plan(plan.id)
    assert Planning.list_placements(plan.id) != []

    assert run_seeds() =~ "seeds skipped"
    assert count(Catalog.Course) == 20
  end
end
