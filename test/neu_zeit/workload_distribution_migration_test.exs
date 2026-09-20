defmodule NeuZeit.WorkloadDistributionMigrationTest do
  use NeuZeit.DataCase, async: true
  import NeuZeit.Fixtures

  alias NeuZeit.{Catalog, Repo}
  alias NeuZeit.Catalog.{Workload, Workloads}

  test "migration preserves legacy float-derived counts without rounding new requirements" do
    term =
      term_fixture(
        academic_hour_minutes: 45,
        grid: %{
          days: ["Mon"],
          slots: [%{start: "08:00", end: "09:00"}, %{start: "09:00", end: "10:00"}]
        }
      )

    above = session_fixture(term: term, week_mask: Enum.to_list(1..5))
    below = session_fixture(term: term, week_mask: Enum.to_list(1..5))

    for {session, hours} <- [
          {above, "6.666666666666667"},
          {below, "6.666666666666666"}
        ] do
      Repo.get!(Workload, session.workload_id)
      |> Ecto.Changeset.change(contact_hours: Decimal.new(hours))
      |> Repo.update!()
    end

    original_ids = Catalog.list_sessions(term.id) |> Enum.map(& &1.id) |> Enum.sort()
    assert {:error, _} = Workloads.check(term.id)
    Repo.query!(backfill_sql())

    assert Repo.get!(Workload, above.workload_id).rounding_mode == :down
    assert Repo.get!(Workload, below.workload_id).rounding_mode == :up
    assert :ok = Workloads.check(term.id)
    assert {:ok, :ready} = Workloads.prepare(term.id)
    assert Catalog.list_sessions(term.id) |> Enum.map(& &1.id) |> Enum.sort() == original_ids

    assert Decimal.equal?(
             Repo.get!(Workload, above.workload_id).contact_hours,
             Decimal.new("6.666666666666667")
           )

    assert {:ok, _} =
             Workloads.save_requirement(term.id, nil, %{
               course_component_id: component_fixture().id,
               teacher_id: teacher_fixture().id,
               cohort_ids: [cohort_fixture().id],
               week_mask: Enum.to_list(1..5),
               duration_slots: 1,
               contact_hours: "6.666666666666667"
             })

    new_row =
      Enum.find(Workloads.list(term.id), &(&1.id not in [above.workload_id, below.workload_id]))

    assert new_row.requirement.rounding_mode == :up
    assert Workloads.meeting_count(new_row) == 6

    ordinary = term_fixture()

    assert {:ok, _} =
             Workloads.save_requirement(ordinary.id, nil, %{
               course_component_id: component_fixture().id,
               teacher_id: teacher_fixture().id,
               cohort_ids: [cohort_fixture().id],
               week_mask: Enum.to_list(1..15),
               duration_slots: 1,
               contact_hours: "45"
             })

    [row] = Workloads.list(ordinary.id)
    assert row.requirement.rounding_mode == :up
    assert Workloads.meeting_count(row) == 23
    assert Decimal.equal?(row.requirement.contact_hours, 45)
  end

  # Run the migration's actual data update inside the sandbox. The schema is
  # already migrated by mix test; replaying DDL would change unrelated tests.
  defp backfill_sql do
    path =
      Path.expand(
        "../../priv/repo/migrations/20260921120000_add_workload_distribution_choices.exs",
        __DIR__
      )

    {_ast, statements} =
      path
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:execute, _, [sql, _down]} = node, statements when is_binary(sql) ->
          {node, [sql | statements]}

        node, statements ->
          {node, statements}
      end)

    [sql] = statements
    sql
  end
end
