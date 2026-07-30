defmodule NeuZeit.Catalog.TeacherAvailabilityTest do
  use NeuZeit.DataCase, async: true

  import NeuZeit.Fixtures

  alias NeuZeit.Catalog
  alias NeuZeit.Planning
  alias NeuZeit.Solver.SpecBuilder

  test "availability is an allow-list and must cover every occupied duration slot" do
    term = term_fixture()
    teacher = teacher_fixture()

    assert {:ok, cells} =
             Catalog.replace_teacher_availability(term.id, teacher.id, [
               %{day: 6, slot: 2},
               %{day: 6, slot: 3}
             ])

    assert Enum.map(cells, &{&1.day, &1.slot}) == [{6, 2}, {6, 3}]

    session =
      session_fixture(
        term: term,
        teacher: teacher,
        duration_slots: 2
      )

    plan = plan_fixture(term: term)
    assert [spec] = SpecBuilder.build!(plan.id).sessions
    assert spec.id == session.id
    assert spec.allowed_starts == [%{day: 6, slot: 2}]
  end

  test "empty availability means unrestricted" do
    term = term_fixture()
    teacher = teacher_fixture()
    session = session_fixture(term: term, teacher: teacher)
    plan = plan_fixture(term: term)

    assert {:ok, []} = Catalog.replace_teacher_availability(term.id, teacher.id, [])
    assert [spec] = SpecBuilder.build!(plan.id).sessions
    assert spec.id == session.id
    assert length(spec.allowed_starts) == 36
  end

  test "availability replacement rolls back when it invalidates a placement" do
    term = term_fixture()
    teacher = teacher_fixture()
    room = room_fixture()
    component = component_fixture(rooms: [room])
    session = session_fixture(term: term, teacher: teacher, component: component)
    plan = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: plan.id,
      session_id: session.id,
      room_id: room.id,
      day: 1,
      slot: 1
    })

    assert {:error, %{errors: [%{type: "teacher_unavailable"}]}} =
             Catalog.replace_teacher_availability(term.id, teacher.id, [
               %{day: 6, slot: 1}
             ])

    assert Catalog.list_teacher_availability(term.id, teacher.id) == []
    assert Planning.check_plan(plan.id) == []
  end

  test "availability replacement rejects a profile intersection with no valid start" do
    term = term_fixture()
    teacher = teacher_fixture()
    profile = slot_profile_fixture(term: term, cells: [%{day: 1, slot: 1}])

    session_fixture(term: term, teacher: teacher, slot_profile_id: profile.id)

    assert {:error, changeset} =
             Catalog.replace_teacher_availability(term.id, teacher.id, [
               %{day: 6, slot: 1}
             ])

    assert %{availability: [message]} = errors_on(changeset)
    assert message =~ "leaves no valid start"
    assert Catalog.list_teacher_availability(term.id, teacher.id) == []
  end

  test "session creation rejects an existing incompatible teacher availability" do
    term = term_fixture()
    teacher = teacher_fixture()
    profile = slot_profile_fixture(term: term, cells: [%{day: 1, slot: 1}])

    assert {:ok, _cells} =
             Catalog.replace_teacher_availability(term.id, teacher.id, [
               %{day: 6, slot: 1}
             ])

    assert {:error, changeset} =
             Catalog.create_session(%{
               term_id: term.id,
               course_component_id: component_fixture().id,
               teacher_id: teacher.id,
               cohort_ids: [cohort_fixture().id],
               week_mask: [1],
               slot_profile_id: profile.id
             })

    assert %{teacher_id: [message]} = errors_on(changeset)
    assert message =~ "leave no valid start"
  end

  test "exceptions cannot bypass availability and availability changes revalidate them" do
    term = term_fixture()
    teacher = teacher_fixture()
    room = room_fixture()
    component = component_fixture(rooms: [room])
    session = session_fixture(term: term, teacher: teacher, component: component, week_mask: [1])
    plan = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: plan.id,
      session_id: session.id,
      room_id: room.id,
      day: 1,
      slot: 1
    })

    assert {:ok, _active} = Planning.publish_plan(plan.id)

    assert {:ok, _cells} =
             Catalog.replace_teacher_availability(term.id, teacher.id, [
               %{day: 1, slot: 1}
             ])

    assert {:error, %{errors: errors}} =
             Planning.create_schedule_exception(%{
               session_id: session.id,
               kind: "move",
               occurrence_date: ~D[2026-08-31],
               new_date: ~D[2026-09-01],
               new_slot: 1,
               new_room_id: room.id,
               reason: "outside availability"
             })

    assert Enum.any?(errors, &(&1.type == "teacher_unavailable"))

    assert {:ok, _cells} = Catalog.replace_teacher_availability(term.id, teacher.id, [])

    assert {:ok, _move} =
             Planning.create_schedule_exception(%{
               session_id: session.id,
               kind: "move",
               occurrence_date: ~D[2026-08-31],
               new_date: ~D[2026-09-01],
               new_slot: 1,
               new_room_id: room.id,
               reason: "temporarily allowed"
             })

    assert {:error, %{errors: replacement_errors}} =
             Catalog.replace_teacher_availability(term.id, teacher.id, [
               %{day: 1, slot: 1}
             ])

    assert Enum.any?(replacement_errors, &(&1.type == "teacher_unavailable"))
    assert Catalog.list_teacher_availability(term.id, teacher.id) == []
  end
end
