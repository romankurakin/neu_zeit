defmodule NeuZeit.PlanCoverageTest do
  use NeuZeit.DataCase, async: true
  import NeuZeit.Fixtures
  alias NeuZeit.{Catalog, Curriculum, Planning}

  test "combines automatic meetings and saved fixed repetitions per group" do
    term = term_fixture()
    component = component_fixture()
    a = cohort_fixture()
    b = cohort_fixture()

    assert {:ok, :saved} =
             Catalog.save_workload(term.id, nil, %{
               course_component_id: component.id,
               teacher_id: teacher_fixture().id,
               cohort_ids: [a.id, b.id],
               week_mask: [1, 2],
               automatic_weeks: true,
               duration_slots: 1,
               contact_hours: "4"
             })

    session_fixture(term: term, component: component, cohorts: [b], week_mask: [1])
    plan = plan_fixture(term: term)

    rows = Curriculum.plan_coverage(plan.id) |> Map.new(&{&1.cohort_id, &1})
    assert rows[a.id].required_hours == 3.0
    assert rows[a.id].status == :under
    assert rows[b.id].planned_hours == 4.5
    assert rows[b.id].required_hours == 4.5
    assert rows[b.id].delta_hours == -4.5
    assert rows[b.id].planned_delta_hours == 0.0
    assert rows[b.id].planned_status == :ok
    assert rows[b.id].status == :under
    refute rows[b.id].missing_workload
  end

  test "shared and parallel cohorts receive separate hours; unplaced demand is planned only" do
    term = term_fixture()
    room = room_fixture()
    component = component_fixture(rooms: [room])
    a = cohort_fixture()
    b = cohort_fixture()

    shared =
      session_fixture(
        term: term,
        component: component,
        cohorts: [a, b],
        week_mask: [1, 2],
        duration_slots: 2
      )

    _parallel = session_fixture(term: term, component: component, cohorts: [b], week_mask: [1])
    plan = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: plan.id,
      session_id: shared.id,
      room_id: room.id,
      day: 1,
      slot: 1
    })

    rows = Curriculum.plan_coverage(plan.id) |> Map.new(&{&1.cohort_id, &1})
    assert rows[a.id].planned_hours == 6.0
    assert rows[b.id].planned_hours == 7.5
    assert rows[a.id].calendar_hours == 6.0
    assert rows[b.id].calendar_hours == 6.0
    assert rows[a.id].required_hours == 6.0
    assert rows[b.id].required_hours == 7.5
  end

  test "dated hours include holidays, cancellations, moves, and unplaced additions only for active plans" do
    term = term_fixture(%{excluded_dates: [~D[2026-09-07]]})
    room = room_fixture()
    component = component_fixture(rooms: [room])
    cohort = cohort_fixture()

    session =
      session_fixture(
        term: term,
        component: component,
        cohorts: [cohort],
        week_mask: [1, 2, 3],
        duration_slots: 2
      )

    plan = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: plan.id,
      session_id: session.id,
      room_id: room.id,
      day: 1,
      slot: 1
    })

    assert [row] = Curriculum.plan_coverage(plan.id)
    assert row.planned_hours == 9.0
    assert row.calendar_hours == 6.0
    {:ok, _} = Planning.publish_plan(plan.id)
    base = %{session_id: session.id, created_by: "Administrator", reason: "Calendar correction"}

    {:ok, _} =
      Planning.create_schedule_exception(
        Map.merge(base, %{kind: "cancel", occurrence_date: ~D[2026-08-31]})
      )

    {:ok, _} =
      Planning.create_schedule_exception(
        Map.merge(base, %{
          kind: "move",
          occurrence_date: ~D[2026-09-14],
          new_date: ~D[2026-09-15],
          new_slot: 3,
          new_room_id: room.id
        })
      )

    extra = session_fixture(term: term, component: component, cohorts: [cohort], week_mask: [1])

    {:ok, _} =
      Planning.create_schedule_exception(%{
        session_id: extra.id,
        created_by: "Administrator",
        reason: "Additional class",
        kind: "add",
        occurrence_date: ~D[2026-09-16],
        new_slot: 1,
        new_room_id: room.id
      })

    assert [row] = Curriculum.plan_coverage(plan.id)
    assert row.planned_hours == 10.5
    assert row.calendar_hours == 4.5
    assert row.exceptions_applied
    {:ok, draft} = Planning.clone_plan(plan.id)
    assert [draft_row] = Curriculum.plan_coverage(draft.id)
    assert draft_row.calendar_hours == 6.0
    refute draft_row.exceptions_applied
  end

  test "unplaced teaching without a cohort is retained as an explicit modelling problem" do
    term = term_fixture()
    session = session_fixture(term: term, week_mask: [1, 2])
    # Model imported data with missing groups.
    Repo.delete_all(from sc in NeuZeit.Catalog.SessionCohort, where: sc.session_id == ^session.id)

    Repo.delete_all(
      from wc in NeuZeit.Catalog.WorkloadCohort, where: wc.workload_id == ^session.workload_id
    )

    plan = plan_fixture(term: term)
    assert [row] = Curriculum.plan_coverage(plan.id)
    assert row.missing_cohort
    assert row.status == :unknown
    assert row.planned_hours == 3.0
    assert row.calendar_hours == 0.0
  end
end
