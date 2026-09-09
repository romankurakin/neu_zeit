defmodule NeuZeit.AutomaticWeeksTest do
  use NeuZeit.DataCase, async: false
  import NeuZeit.Fixtures
  alias NeuZeit.{Catalog, Curriculum, Planning}
  alias NeuZeit.Solver.{PlanRuns, ResultValidator, SpecBuilder}

  test "hours become dated meetings, retaining weeks through edits, copies and publication" do
    term = term_fixture(ends_on: ~D[2026-09-20], excluded_dates: [~D[2026-09-01]])
    component = component_fixture()
    teacher = teacher_fixture()
    cohort = cohort_fixture()
    {:ok, _} = Catalog.replace_teacher_availability(term.id, teacher.id, [%{day: 2, slot: 1}])
    profile = slot_profile_fixture(term: term, cells: [%{day: 2, slot: 1}])

    attrs = %{
      course_component_id: component.id,
      teacher_id: teacher.id,
      cohort_ids: [cohort.id],
      week_mask: [1, 2, 3],
      automatic_weeks: true,
      contact_hours: "4",
      duration_slots: 1,
      slot_profile_id: profile.id
    }

    {:ok, :saved} = Catalog.save_workload(term.id, nil, attrs)
    plan = plan_fixture(term: term)
    assert {:ok, _} = PlanRuns.solve(plan.id)
    placements = Planning.list_placements(plan.id)
    assert Enum.sort(Enum.map(placements, & &1.week_mask)) == [[2], [3]]
    assert Enum.all?(placements, &(&1.day == 2 && &1.slot == 1))
    assert [%{planned_hours: 3.0, calendar_hours: 3.0}] = Curriculum.plan_coverage(plan.id)
    assert Planning.check_plan(plan.id) == []

    first = hd(placements)
    {:ok, locked} = Planning.update_placement(first, %{locked: true})
    assert {:ok, _} = PlanRuns.solve(plan.id)
    assert Planning.get_placement!(locked.id).week_mask == first.week_mask
    {:ok, copy} = Planning.clone_plan(plan.id)
    assert Enum.sort(Enum.map(Planning.list_placements(copy.id), & &1.week_mask)) == [[2], [3]]
    assert {:ok, _} = Planning.publish_plan(plan.id)
    assert length(Planning.project_plan(plan.id).occurrences) == 2

    spec = SpecBuilder.build!(copy.id)

    bad =
      Map.new(
        Planning.list_placements(copy.id),
        &{&1.session_id, %{room: &1.room_id, day: &1.day, slot: &1.slot, weeks: [1, 2]}}
      )

    assert {:error, _} = ResultValidator.validate(copy.id, spec, %{"assignment" => bad})
  end

  test "rejects a generated meeting on an excluded date at both input and solver boundaries" do
    term = term_fixture(ends_on: ~D[2026-09-13], excluded_dates: [~D[2026-09-01]])
    session = session_fixture(term: term, automatic_weeks: true, week_mask: [1, 2])
    plan = plan_fixture(term: term)
    room = hd(session.course_component.allowed_rooms)

    attrs = %{
      plan_id: plan.id,
      session_id: session.id,
      room_id: room.id,
      day: 2,
      slot: 1,
      week_mask: [1]
    }

    assert {:error, _} = Planning.create_placement(attrs)
    spec = SpecBuilder.build!(plan.id)
    result = %{"assignment" => %{session.id => %{day: 2, slot: 1, room: room.id, weeks: [1]}}}
    assert {:error, _} = ResultValidator.validate(plan.id, spec, result)
    assert Planning.list_placements(plan.id) == []
  end
end
