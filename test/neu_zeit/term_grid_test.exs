defmodule NeuZeit.TermGridTest do
  use NeuZeit.DataCase, async: true
  import NeuZeit.Fixtures
  alias NeuZeit.{Catalog, Config, Curriculum, Planning}

  test "new terms copy defaults and custom grids drive hours, constraints and the solver" do
    other = term_fixture()

    grid = %{
      days: ~w(Mon Tue Wed Thu Fri Sat Sun),
      slots: [
        %{start: "10:00", end: "11:00"},
        %{start: "11:15", end: "12:15"},
        %{start: "13:00", end: "14:00"}
      ]
    }

    term = term_fixture(grid: grid)
    component = component_fixture()

    assert {:ok, :saved} =
             Catalog.save_workload(term.id, nil, %{
               course_component_id: component.id,
               teacher_id: teacher_fixture().id,
               cohort_ids: [cohort_fixture().id],
               week_mask: [1],
               duration_slots: 1,
               contact_hours: "4"
             })

    assert length(Catalog.list_sessions(term.id)) == 3
    assert Catalog.get_term!(other.id).grid == Config.grid!()
    plan = plan_fixture(term: term)
    spec = NeuZeit.Solver.SpecBuilder.build!(plan.id)
    assert spec.grid == %{days_count: 7, slots_per_day: 3}

    for {session, slot} <- Enum.with_index(Catalog.list_sessions(term.id), 1) do
      placement_fixture(
        plan_id: plan.id,
        session_id: session.id,
        room_id: hd(component.allowed_rooms).id,
        day: 7,
        slot: slot,
        week_mask: [1]
      )
    end

    assert {:ok, _} = Planning.publish_plan(plan.id)
    assert [coverage] = Curriculum.plan_coverage(plan.id)
    assert coverage.required_hours == 3.0
    assert coverage.calendar_hours == 3.0
  end

  test "time settings are protected as soon as term-specific inputs exist" do
    term = term_fixture()
    teacher = teacher_fixture()

    assert {:ok, _} =
             Catalog.replace_teacher_availability(term.id, teacher.id, [%{day: 1, slot: 1}])

    assert {:error, _} =
             Catalog.update_term(term, %{grid: %{term.grid | days: ~w(Mon Tue Wed Thu Fri)}})

    assert {:error, _} = Catalog.update_term(term, %{academic_hour_minutes: 60})
    assert Catalog.get_term!(term.id).grid == term.grid
  end

  test "grids reject overlaps, unequal durations, invalid times and reordered weekdays" do
    for grid <- [
          %{days: ["Tue"], slots: [%{start: "09:00", end: "10:00"}]},
          %{days: ["Mon"], slots: []},
          %{days: ["Mon"], slots: [%{start: "09:00", end: "08:00"}]},
          %{days: ["Mon"], slots: [%{start: "25:00", end: "26:00"}]},
          %{
            days: ["Mon"],
            slots: [%{start: "08:00", end: "09:30"}, %{start: "09:00", end: "10:30"}]
          },
          %{
            days: ["Mon"],
            slots: [%{start: "08:00", end: "09:30"}, %{start: "10:00", end: "11:00"}]
          }
        ] do
      assert {:error, _} =
               Catalog.create_term(%{
                 name: "Invalid",
                 starts_on: ~D[2026-08-31],
                 ends_on: ~D[2026-09-20],
                 grid: grid
               })
    end
  end

  test "different terms compare clock times rather than slot numbers" do
    room = room_fixture()
    teacher = teacher_fixture()
    component = component_fixture(rooms: [room])
    first = term_fixture(grid: %{days: ["Mon"], slots: [%{start: "08:00", end: "09:30"}]})

    first_session =
      session_fixture(term: first, component: component, teacher: teacher, week_mask: [1])

    first_plan = plan_fixture(term: first)

    placement_fixture(
      plan_id: first_plan.id,
      session_id: first_session.id,
      room_id: room.id,
      day: 1,
      slot: 1
    )

    assert {:ok, _} = Planning.publish_plan(first_plan.id)

    second =
      term_fixture(
        grid: %{
          days: ["Mon"],
          slots: [%{start: "09:30", end: "11:00"}, %{start: "11:30", end: "13:00"}]
        }
      )

    second_session =
      session_fixture(term: second, component: component, teacher: teacher, week_mask: [1])

    second_plan = plan_fixture(term: second)

    placement_fixture(
      plan_id: second_plan.id,
      session_id: second_session.id,
      room_id: room.id,
      day: 1,
      slot: 1
    )

    assert {:ok, _} = Planning.publish_plan(second_plan.id)

    third =
      term_fixture(
        grid: %{
          days: ["Mon"],
          slots: [%{start: "07:00", end: "08:30"}, %{start: "08:45", end: "10:15"}]
        }
      )

    third_session =
      session_fixture(term: third, component: component, teacher: teacher, week_mask: [1])

    third_plan = plan_fixture(term: third)

    assert {:error, _} =
             Planning.create_placement(%{
               plan_id: third_plan.id,
               session_id: third_session.id,
               room_id: room.id,
               day: 1,
               slot: 2
             })

    spec = NeuZeit.Solver.SpecBuilder.build!(third_plan.id)
    assert [%{blocked_assignments: blocked}] = spec.sessions
    assert Enum.any?(blocked, &(&1.slot == 2))
  end
end
