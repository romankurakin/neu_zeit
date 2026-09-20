defmodule NeuZeit.PartialPublicationTest do
  use NeuZeit.DataCase, async: true
  import NeuZeit.Fixtures
  alias NeuZeit.{Catalog, Planning, Repo}

  test "publishes the first week after confirmation and later extends the timetable" do
    term = term_fixture()
    component = component_fixture()
    teacher = teacher_fixture()
    cohort = cohort_fixture()

    session_fixture(
      term: term,
      component: component,
      teacher: teacher,
      cohorts: [cohort],
      automatic_weeks: true,
      week_mask: [1, 2, 3]
    )

    [existing] = Catalog.list_workload(term.id)

    {:ok, :saved} =
      Catalog.save_workload(term.id, existing, %{
        course_component_id: component.id,
        teacher_id: teacher.id,
        cohort_ids: [cohort.id],
        week_mask: [1, 2, 3],
        duration_slots: 1,
        contact_hours: "6"
      })

    [first, second, third] = Catalog.list_sessions(term.id)
    plan = plan_fixture(term: term)
    room = hd(component.allowed_rooms)

    placement_fixture(
      plan_id: plan.id,
      session_id: first.id,
      room_id: room.id,
      day: 1,
      slot: 1,
      week_mask: [1]
    )

    assert {:error, _} = Planning.publish_plan(plan.id)
    assert {:error, _} = Planning.publish_plan(plan.id, allow_partial: "true")
    assert {:ok, _} = Planning.publish_plan(plan.id, allow_partial: true)
    projection = Planning.project_active_term(term.id)
    assert [occurrence] = projection.occurrences
    assert occurrence.date == term.starts_on
    assert Enum.sort(projection.unplaced_session_ids) == Enum.sort([second.id, third.id])
    [load] = Catalog.list_workload(term.id)
    assert Decimal.equal?(load.requirement.contact_hours, 6)
    {:ok, draft} = Planning.clone_plan(plan.id)

    placement_fixture(
      plan_id: draft.id,
      session_id: second.id,
      room_id: room.id,
      day: 1,
      slot: 1,
      week_mask: [2]
    )

    assert {:ok, _} = Planning.publish_plan(draft.id, allow_partial: true)
    assert Planning.get_plan!(plan.id).status == "archived"
    assert length(Planning.project_active_term(term.id).occurrences) == 2
  end

  test "confirmation cannot bypass invalid placements or missing generated workload",
    do: check_guards()

  defp check_guards do
    term = term_fixture()
    session = session_fixture(term: term)
    _unplaced = session_fixture(term: term)
    plan = plan_fixture(term: term)

    placement =
      placement_fixture(
        plan_id: plan.id,
        session_id: session.id,
        room_id: hd(session.course_component.allowed_rooms).id,
        day: 1,
        slot: 1
      )

    Repo.update_all(from(p in NeuZeit.Planning.Placement, where: p.id == ^placement.id),
      set: [slot: 100]
    )

    assert {:error, _} = Planning.publish_plan(plan.id, allow_partial: true)
    Repo.delete!(placement)
    Repo.delete!(session)
    assert {:error, {:conflict, _}} = Planning.publish_plan(plan.id, allow_partial: true)
    assert Planning.get_plan!(plan.id).status == "draft"
  end
end
