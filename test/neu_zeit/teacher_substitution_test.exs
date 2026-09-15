defmodule NeuZeit.TeacherSubstitutionTest do
  use NeuZeit.DataCase, async: true
  import NeuZeit.Fixtures
  alias NeuZeit.{Catalog, Planning}

  setup do
    term = term_fixture(excluded_dates: [~D[2026-09-14]])
    session = session_fixture(term: term, week_mask: [1, 2, 3], duration_slots: 2)
    room = hd(session.course_component.allowed_rooms)
    plan = plan_fixture(term: term)

    placement =
      placement_fixture(
        plan_id: plan.id,
        session_id: session.id,
        room_id: room.id,
        day: 1,
        slot: 1
      )

    {:ok, plan} = Planning.publish_plan(plan.id)
    teacher = teacher_fixture()

    attrs = %{
      session_id: session.id,
      kind: "substitute",
      occurrence_date: ~D[2026-08-31],
      new_teacher_id: teacher.id,
      reason: "Covering English",
      created_by: "Admin"
    }

    %{
      term: term,
      session: session,
      room: room,
      plan: plan,
      placement: placement,
      teacher: teacher,
      attrs: attrs
    }
  end

  test "replacement changes one date and reverting restores its teacher", c do
    assert {:ok, exception} = Planning.create_schedule_exception(c.attrs)
    assert [first, second] = Planning.project_active_term(c.term.id).occurrences
    assert first.teacher_id == c.teacher.id
    assert first.source == :substitute
    assert first.date == ~D[2026-08-31]
    assert {first.slot, first.room_id, first.duration_slots} == {1, c.room.id, 2}
    assert second.teacher_id == c.session.teacher_id
    assert Catalog.get_session!(c.session.id).teacher_id == c.session.teacher_id
    assert [row] = Catalog.list_workload(c.term.id)
    assert row.requirement.teacher_id == c.session.teacher_id
    assert {:ok, draft} = Planning.clone_plan(c.plan.id)

    assert Enum.all?(
             Planning.project_plan(draft.id).occurrences,
             &(&1.teacher_id == c.session.teacher_id)
           )

    assert {:ok, _} = Planning.publish_plan(draft.id)
    assert hd(Planning.project_plan(draft.id).occurrences).teacher_id == c.teacher.id
    assert {:ok, _} = Planning.update_schedule_exception(exception, %{status: "reverted"})

    assert Enum.all?(
             Planning.project_active_term(c.term.id).occurrences,
             &(&1.teacher_id == c.session.teacher_id)
           )
  end

  test "requires a teacher and an existing teaching date without a second override", c do
    assert {:error, missing} =
             Planning.create_schedule_exception(Map.delete(c.attrs, :new_teacher_id))

    assert errors_on(missing).new_teacher_id == ["can't be blank"]

    assert {:error, _} =
             Planning.create_schedule_exception(%{c.attrs | occurrence_date: ~D[2026-09-01]})

    assert {:error, _} =
             Planning.create_schedule_exception(%{c.attrs | occurrence_date: ~D[2026-09-14]})

    assert {:ok, _} = Planning.create_schedule_exception(c.attrs)
    assert {:error, _} = Planning.create_schedule_exception(c.attrs)

    assert {:error, _} =
             Planning.create_schedule_exception(
               c.attrs
               |> Map.put(:kind, "cancel")
               |> Map.delete(:new_teacher_id)
             )

    assert length(Planning.list_schedule_exceptions(c.term.id)) == 1
  end

  test "a teacher used in a dated change cannot be deleted", c do
    assert {:ok, _} = Planning.create_schedule_exception(c.attrs)
    assert {:error, changeset} = Catalog.delete_teacher(c.teacher)
    assert errors_on(changeset).id == ["is used by a one-off change"]
    assert Catalog.get_teacher!(c.teacher.id)
  end

  test "checks every occupied slot of the replacement teacher and later availability edits", c do
    assert {:ok, _} =
             Catalog.replace_teacher_availability(c.term.id, c.teacher.id, [%{day: 1, slot: 1}])

    assert {:error, %{errors: errors}} = Planning.create_schedule_exception(c.attrs)
    assert Enum.any?(errors, &(&1.type == "teacher_unavailable"))

    assert {:ok, _} =
             Catalog.replace_teacher_availability(c.term.id, c.teacher.id, [
               %{day: 1, slot: 1},
               %{day: 1, slot: 2}
             ])

    assert {:ok, _} = Planning.create_schedule_exception(c.attrs)

    assert {:error, %{errors: errors}} =
             Catalog.replace_teacher_availability(c.term.id, c.teacher.id, [%{day: 2, slot: 1}])

    assert Enum.any?(errors, &(&1.type == "teacher_unavailable"))
  end

  test "a substitute already teaching another group is rejected", c do
    other = session_fixture(term: c.term, teacher: c.teacher, week_mask: [1])
    {:ok, draft} = Planning.clone_plan(c.plan.id)

    placement_fixture(
      plan_id: draft.id,
      session_id: other.id,
      room_id: hd(other.course_component.allowed_rooms).id,
      day: 1,
      slot: 2
    )

    assert {:ok, _} = Planning.publish_plan(draft.id)
    assert {:error, %{errors: errors}} = Planning.create_schedule_exception(c.attrs)
    assert Enum.any?(errors, &(&1.type == "teacher_conflict"))
  end

  test "replacement reserves the substitute across terms and releases the original teacher", c do
    assert {:ok, exception} = Planning.create_schedule_exception(c.attrs)
    other_term = term_fixture()
    substitute_session = session_fixture(term: other_term, teacher: c.teacher, week_mask: [1])

    original_session =
      session_fixture(term: other_term, teacher: c.session.teacher, week_mask: [1])

    other_plan = plan_fixture(term: other_term)

    candidate = %{
      plan_id: other_plan.id,
      session_id: substitute_session.id,
      room_id: hd(substitute_session.course_component.allowed_rooms).id,
      day: 1,
      slot: 2
    }

    assert {:error, %{errors: errors}} = Planning.create_placement(candidate)

    assert Enum.any?(
             errors,
             &(&1.type == "external_teacher_conflict" and &1.other_teacher == c.teacher.name)
           )

    spec = NeuZeit.Solver.SpecBuilder.build!(other_plan.id)
    generated = Enum.find(spec.sessions, &(&1.id == substitute_session.id))
    assert %{day: 1, slot: 2, room: candidate.room_id} in generated.blocked_assignments

    placement_fixture(%{
      candidate
      | session_id: original_session.id,
        room_id: hd(original_session.course_component.allowed_rooms).id
    })

    placement_fixture(%{candidate | day: 2})
    assert {:ok, _} = Planning.publish_plan(other_plan.id)

    assert {:error, %{errors: errors}} =
             Planning.update_schedule_exception(exception, %{status: "reverted"})

    assert Enum.any?(errors, &(&1.type == "external_teacher_conflict"))
    assert Planning.get_schedule_exception!(exception.id).status == "active"
  end

  test "moving and adding a class can also replace its teacher", c do
    assert {:ok, moved} =
             Planning.create_schedule_exception(
               Map.merge(c.attrs, %{
                 kind: "move",
                 new_date: ~D[2026-09-01],
                 new_slot: 2,
                 new_room_id: c.room.id
               })
             )

    assert {:ok, added} =
             Planning.create_schedule_exception(
               Map.merge(c.attrs, %{
                 kind: "add",
                 occurrence_date: ~D[2026-09-02],
                 new_slot: 3,
                 new_room_id: c.room.id
               })
             )

    occurrences = Planning.project_active_term(c.term.id).occurrences

    for id <- [moved.id, added.id] do
      assert Enum.find(occurrences, &(&1.exception_id == id)).teacher_id == c.teacher.id
    end
  end

  test "publishing a changed template cannot orphan a teacher replacement", c do
    assert {:ok, _} = Planning.create_schedule_exception(c.attrs)
    {:ok, draft} = Planning.clone_plan(c.plan.id)
    [placement] = Planning.list_placements(draft.id)
    assert {:ok, _} = Planning.update_placement(placement, %{day: 2})
    assert {:error, %{errors: errors}} = Planning.publish_plan(draft.id)
    assert Enum.any?(errors, &(&1.type == "orphaned_exception"))
  end
end
