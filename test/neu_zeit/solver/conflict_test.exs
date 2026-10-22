defmodule NeuZeit.Solver.ConflictTest do
  use NeuZeit.DataCase, async: false

  import NeuZeit.Fixtures

  alias NeuZeit.Planning

  setup do
    term = term_fixture()
    for _ <- 1..2, do: room_fixture()
    teacher = teacher_fixture(name: "Anna Weber")

    # Separate groups and unrestricted rooms leave the teacher as the only shared resource.
    sessions =
      for _ <- 1..3 do
        session_fixture(
          term: term,
          component: component_fixture(rooms: []),
          teacher: teacher,
          cohorts: [cohort_fixture()],
          week_mask: [1, 2]
        )
      end

    %{term: term, teacher: teacher, sessions: sessions}
  end

  @tag timeout: 60_000
  test "a teacher available in fewer slots than their sessions is named with those sessions",
       %{term: term, teacher: teacher, sessions: sessions} do
    teacher_availability_fixture(
      term: term,
      teacher: teacher,
      cells: [%{day: 1, slot: 1}, %{day: 1, slot: 2}]
    )

    plan = plan_fixture(term: term)
    session_ids = sessions |> Enum.map(& &1.id) |> Enum.sort()
    teacher_id = teacher.id

    assert {:error, %{errors: [%{solver_status: "INFEASIBLE", conflict: conflict}]}} =
             Planning.solve_plan(plan.id)

    assert %{
             "minimal" => true,
             "rules" => [
               %{"kind" => "teacher_load", "id" => ^teacher_id, "session_ids" => ^session_ids},
               %{
                 "kind" => "teacher_availability",
                 "id" => ^teacher_id,
                 "session_ids" => ^session_ids
               }
             ],
             "session_ids" => ^session_ids
           } = conflict

    assert %{
             rules: [
               %{kind: :teacher_availability, teacher: %{name: "Anna Weber"}, slots: 2},
               %{kind: :teacher_load, teacher: %{name: "Anna Weber"}}
             ],
             sessions: described
           } = Planning.describe_conflict(term.id, conflict)

    assert described |> Enum.map(& &1.id) |> Enum.sort() == session_ids
  end

  test "enough availability gives a timetable without a conflict",
       %{term: term, teacher: teacher} do
    teacher_availability_fixture(
      term: term,
      teacher: teacher,
      cells: for(slot <- 1..3, do: %{day: 1, slot: slot})
    )

    plan = plan_fixture(term: term)

    assert {:ok, %{"status" => status} = result} = Planning.solve_plan(plan.id)
    assert status in ["OPTIMAL", "FEASIBLE"]
    refute Map.has_key?(result, "conflict")
  end

  test "rules whose records were removed are left out", %{term: term, sessions: [session | _]} do
    conflict = %{
      "rules" => [
        %{"kind" => "teacher_load", "id" => Ecto.UUID.generate(), "session_ids" => [session.id]},
        %{"kind" => "unknown", "id" => "x", "session_ids" => [session.id]}
      ],
      "session_ids" => [session.id]
    }

    assert Planning.describe_conflict(term.id, conflict) == nil
    assert Planning.describe_conflict(term.id, nil) == nil
  end
end
