defmodule NeuZeit.CatalogTest do
  use NeuZeit.DataCase, async: true

  import NeuZeit.Fixtures

  alias NeuZeit.Catalog

  test "courses require only a title, and optional codes remain unique" do
    assert {:ok, first} = Catalog.create_course(%{title: "Mathematics"})
    assert {:ok, second} = Catalog.create_course(%{title: "Physics", code: "  "})
    assert first.code == nil
    assert second.code == nil
    assert {:ok, coded} = Catalog.update_course(first, %{code: "MAT101"})
    assert {:error, changeset} = Catalog.update_course(second, %{code: "MAT101"})
    assert %{code: ["has already been taken"]} = errors_on(changeset)
    assert {:ok, cleared} = Catalog.update_course(coded, %{code: ""})
    assert cleared.code == nil
    assert Catalog.get_course!(first.id).title == "Mathematics"
    assert {:error, changeset} = Catalog.create_course(%{code: "NO-TITLE"})
    assert %{title: ["can't be blank"]} = errors_on(changeset)
  end

  test "terms derive their week count" do
    term = term_fixture(starts_on: ~D[2026-08-31], ends_on: ~D[2026-12-19])

    assert term.weeks_count == 16
  end

  test "terms can start on any weekday and count partial weeks" do
    for {starts_on, ends_on, weeks} <- [
          {~D[2026-09-01], ~D[2026-09-07], 2},
          {~D[2026-09-06], ~D[2026-09-07], 2},
          {~D[2026-09-02], ~D[2026-09-04], 1},
          {~D[2026-09-01], ~D[2026-12-19], 16}
        ] do
      term = term_fixture(starts_on: starts_on, ends_on: ends_on)
      assert term.starts_on == starts_on
      assert term.weeks_count == weeks
    end
  end

  test "schemas generate UUIDv7 identifiers" do
    term = term_fixture()

    assert {:ok, <<_::binary-size(14), "7", _::binary>>} = Ecto.UUID.cast(term.id)
  end

  test "sessions store normalized explicit week masks" do
    term = term_fixture()
    component = component_fixture()
    teacher = teacher_fixture()
    cohort = cohort_fixture()

    {:ok, session} =
      NeuZeit.Fixtures.create_session(%{
        term_id: term.id,
        course_component_id: component.id,
        teacher_id: teacher.id,
        week_mask: [3, 1, 1],
        cohort_ids: [cohort.id]
      })

    assert session.week_mask == [1, 3]
  end

  test "does not create a course component when an allowed room does not exist" do
    course = course_fixture()

    assert {:error, changeset} =
             Catalog.create_course_component(%{
               course_id: course.id,
               kind: "lecture",
               allowed_room_ids: ["00000000-0000-7000-8000-000000000000"]
             })

    assert %{allowed_room_ids: ["contains unknown ids"]} = errors_on(changeset)
    assert Catalog.list_course_components() == []
  end

  test "de-duplicates allowed room ids for a course component" do
    course = course_fixture()
    room = room_fixture()

    assert {:ok, component} =
             Catalog.create_course_component(%{
               course_id: course.id,
               kind: "seminar",
               allowed_room_ids: [room.id, room.id]
             })

    component = Catalog.get_course_component!(component.id)

    assert Enum.map(component.allowed_rooms, & &1.id) == [room.id]
  end

  test "does not create a session when a cohort does not exist" do
    term = term_fixture()
    component = component_fixture()
    teacher = teacher_fixture()

    assert {:error, changeset} =
             NeuZeit.Fixtures.create_session(%{
               term_id: term.id,
               course_component_id: component.id,
               teacher_id: teacher.id,
               week_mask: [1],
               cohort_ids: ["00000000-0000-7000-8000-000000000000"]
             })

    assert %{cohort_ids: ["contains unknown ids"]} = errors_on(changeset)
    assert Catalog.list_sessions() == []
  end

  test "de-duplicates cohort ids for a session" do
    term = term_fixture()
    component = component_fixture()
    teacher = teacher_fixture()
    cohort = cohort_fixture()

    assert {:ok, session} =
             NeuZeit.Fixtures.create_session(%{
               term_id: term.id,
               course_component_id: component.id,
               teacher_id: teacher.id,
               week_mask: [1],
               cohort_ids: [cohort.id, cohort.id]
             })

    session = Catalog.get_session!(session.id)

    assert Enum.map(session.cohorts, & &1.id) == [cohort.id]
  end

  test "excluded dates must be teaching days within the term" do
    term = term_fixture(starts_on: ~D[2026-08-31], ends_on: ~D[2026-12-19])

    assert {:error, changeset} = Catalog.update_term(term, %{excluded_dates: [~D[2027-01-01]]})
    assert %{excluded_dates: ["must be within the term"]} = errors_on(changeset)

    # 2026-09-06 is a Sunday
    assert {:error, changeset} = Catalog.update_term(term, %{excluded_dates: [~D[2026-09-06]]})
    assert %{excluded_dates: ["must fall on teaching days"]} = errors_on(changeset)

    assert {:ok, term} =
             Catalog.update_term(term, %{
               excluded_dates: [~D[2026-09-08], ~D[2026-09-07], ~D[2026-09-07]]
             })

    assert term.excluded_dates == [~D[2026-09-07], ~D[2026-09-08]]
  end

  test "add_excluded_date and remove_excluded_date manage single holidays" do
    term = term_fixture(starts_on: ~D[2026-08-31], ends_on: ~D[2026-12-19])

    assert {:ok, term} = Catalog.add_excluded_date(term, ~D[2026-09-07])
    assert term.excluded_dates == [~D[2026-09-07]]

    # idempotent
    assert {:ok, term} = Catalog.add_excluded_date(term, ~D[2026-09-07])
    assert term.excluded_dates == [~D[2026-09-07]]

    assert {:ok, term} = Catalog.remove_excluded_date(term, ~D[2026-09-07])
    assert term.excluded_dates == []
  end

  test "terms cannot shrink below weeks used by sessions or placements" do
    term = term_fixture(starts_on: ~D[2026-08-31], ends_on: ~D[2026-12-19])
    session_fixture(term: term, week_mask: [1, 10])

    assert {:error, changeset} = Catalog.update_term(term, %{ends_on: ~D[2026-10-24]})
    assert %{ends_on: [message]} = errors_on(changeset)
    assert message =~ "week 10"

    assert {:ok, term} = Catalog.update_term(term, %{ends_on: ~D[2026-11-07]})
    assert term.weeks_count == 10
  end

  test "session term cannot change after creation" do
    session = session_fixture()
    other_term = term_fixture()

    assert {:error, changeset} =
             NeuZeit.Catalog.Sessions.update_generated_session(session, %{term_id: other_term.id})

    assert %{term_id: ["is read-only"]} = errors_on(changeset)
  end

  test "session week_mask changes propagate to placements in draft and active plans" do
    term = term_fixture()
    room = room_fixture()
    component = component_fixture(rooms: [room])
    session = session_fixture(term: term, component: component, week_mask: [1, 2])
    plan = plan_fixture(term: term)

    placement =
      placement_fixture(%{
        plan_id: plan.id,
        session_id: session.id,
        room_id: room.id,
        day: 1,
        slot: 1
      })

    assert {:ok, _session} =
             NeuZeit.Catalog.Sessions.update_generated_session(session, %{week_mask: [1, 2, 3]})

    assert NeuZeit.Planning.get_placement!(placement.id).week_mask == [1, 2, 3]
    assert NeuZeit.Planning.check_plan(plan.id) == []
  end

  test "session week_mask changes are rejected when they would break a plan" do
    term = term_fixture()
    room = room_fixture()
    component = component_fixture(rooms: [room])
    session_a = session_fixture(term: term, component: component, week_mask: [1])
    session_b = session_fixture(term: term, component: component, week_mask: [2])
    plan = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: plan.id,
      session_id: session_a.id,
      room_id: room.id,
      day: 1,
      slot: 1
    })

    placement_b =
      placement_fixture(%{
        plan_id: plan.id,
        session_id: session_b.id,
        room_id: room.id,
        day: 1,
        slot: 1
      })

    assert {:error, %{errors: errors}} =
             NeuZeit.Catalog.Sessions.update_generated_session(session_a, %{week_mask: [1, 2]})

    assert Enum.any?(errors, &(&1.type == "room_conflict"))
    assert NeuZeit.Planning.get_placement!(placement_b.id).week_mask == [2]
  end

  test "teacher changes revalidate the active plan" do
    term = term_fixture()
    room_a = room_fixture()
    room_b = room_fixture()
    component = component_fixture(rooms: [room_a, room_b])
    teacher_a = teacher_fixture()
    teacher_b = teacher_fixture()
    teacher_c = teacher_fixture()

    session_a =
      session_fixture(
        term: term,
        component: component,
        teacher: teacher_a,
        cohorts: [cohort_fixture()]
      )

    session_b =
      session_fixture(
        term: term,
        component: component,
        teacher: teacher_b,
        cohorts: [cohort_fixture()]
      )

    plan = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: plan.id,
      session_id: session_a.id,
      room_id: room_a.id,
      day: 1,
      slot: 1
    })

    placement_fixture(%{
      plan_id: plan.id,
      session_id: session_b.id,
      room_id: room_b.id,
      day: 1,
      slot: 1
    })

    assert {:ok, _plan} = NeuZeit.Planning.publish_plan(plan.id)

    assert {:error, %{errors: errors}} =
             NeuZeit.Catalog.Sessions.update_generated_session(session_b, %{
               teacher_id: teacher_a.id
             })

    assert Enum.any?(errors, &(&1.type == "teacher_conflict"))
    assert Catalog.get_session!(session_b.id).teacher_id == teacher_b.id

    assert {:ok, updated} =
             NeuZeit.Catalog.Sessions.update_generated_session(session_b, %{
               teacher_id: teacher_c.id
             })

    assert updated.teacher_id == teacher_c.id
  end

  test "cohort replacements revalidate the active plan" do
    term = term_fixture()
    room_a = room_fixture()
    room_b = room_fixture()
    component = component_fixture(rooms: [room_a, room_b])
    cohort_a = cohort_fixture()
    cohort_b = cohort_fixture()
    cohort_c = cohort_fixture()

    session_a =
      session_fixture(
        term: term,
        component: component,
        teacher: teacher_fixture(),
        cohorts: [cohort_a]
      )

    session_b =
      session_fixture(
        term: term,
        component: component,
        teacher: teacher_fixture(),
        cohorts: [cohort_b]
      )

    plan = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: plan.id,
      session_id: session_a.id,
      room_id: room_a.id,
      day: 1,
      slot: 1
    })

    placement_fixture(%{
      plan_id: plan.id,
      session_id: session_b.id,
      room_id: room_b.id,
      day: 1,
      slot: 1
    })

    assert {:ok, _plan} = NeuZeit.Planning.publish_plan(plan.id)

    assert {:error, %{errors: errors}} =
             NeuZeit.Catalog.Sessions.update_generated_session(session_b, %{
               cohort_ids: [cohort_a.id]
             })

    assert Enum.any?(errors, &(&1.type == "cohort_conflict"))
    assert Enum.map(Catalog.get_session!(session_b.id).cohorts, & &1.id) == [cohort_b.id]

    assert {:ok, _updated} =
             NeuZeit.Catalog.Sessions.update_generated_session(session_b, %{
               cohort_ids: [cohort_c.id]
             })

    assert Enum.map(Catalog.get_session!(session_b.id).cohorts, & &1.id) == [cohort_c.id]
  end

  test "component changes revalidate placed-room eligibility" do
    term = term_fixture()
    room_a = room_fixture()
    room_b = room_fixture()
    original_component = component_fixture(rooms: [room_a])
    excluding_component = component_fixture(rooms: [room_b])
    compatible_component = component_fixture(rooms: [room_a, room_b])
    session = session_fixture(term: term, component: original_component)
    plan = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: plan.id,
      session_id: session.id,
      room_id: room_a.id,
      day: 1,
      slot: 1
    })

    assert {:ok, _plan} = NeuZeit.Planning.publish_plan(plan.id)

    assert {:error, %{errors: errors}} =
             NeuZeit.Catalog.Sessions.update_generated_session(session, %{
               course_component_id: excluding_component.id
             })

    assert Enum.any?(errors, &(&1.type == "room_not_allowed"))
    assert Catalog.get_session!(session.id).course_component_id == original_component.id

    assert {:ok, updated} =
             NeuZeit.Catalog.Sessions.update_generated_session(session, %{
               course_component_id: compatible_component.id
             })

    assert updated.course_component_id == compatible_component.id
  end

  test "allowed-room edits revalidate affected active plans" do
    term = term_fixture()
    room_a = room_fixture()
    room_b = room_fixture()
    component = component_fixture(rooms: [])
    session = session_fixture(term: term, component: component)
    plan = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: plan.id,
      session_id: session.id,
      room_id: room_a.id,
      day: 1,
      slot: 1
    })

    assert {:ok, _plan} = NeuZeit.Planning.publish_plan(plan.id)

    assert {:error, %{errors: errors}} =
             Catalog.update_course_component(component, %{allowed_room_ids: [room_b.id]})

    assert Enum.any?(errors, &(&1.type == "room_not_allowed"))

    assert Catalog.get_course_component!(component.id).allowed_rooms == []

    assert NeuZeit.Planning.check_plan(plan.id) == []
  end

  test "allowed-room edits revalidate active exception rooms" do
    term = term_fixture()
    template_room = room_fixture()
    exception_room = room_fixture()
    component = component_fixture(rooms: [template_room, exception_room])
    session = session_fixture(term: term, component: component)
    plan = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: plan.id,
      session_id: session.id,
      room_id: template_room.id,
      day: 1,
      slot: 1
    })

    assert {:ok, _plan} = NeuZeit.Planning.publish_plan(plan.id)

    assert {:ok, _move} =
             NeuZeit.Planning.create_schedule_exception(%{
               session_id: session.id,
               kind: "move",
               occurrence_date: ~D[2026-08-31],
               new_date: ~D[2026-09-01],
               new_slot: 2,
               new_room_id: exception_room.id,
               created_by: "Test administrator",
               reason: "move"
             })

    assert {:error, %{errors: errors}} =
             Catalog.update_course_component(component, %{
               allowed_room_ids: [template_room.id]
             })

    assert Enum.any?(errors, &(&1.type == "room_not_allowed"))

    assert Catalog.get_course_component!(component.id).allowed_rooms
           |> Enum.map(& &1.id)
           |> Enum.sort() == Enum.sort([template_room.id, exception_room.id])
  end

  test "session resource changes revalidate active exception targets" do
    term = term_fixture()
    room_a = room_fixture()
    room_b = room_fixture()
    component = component_fixture(rooms: [room_a, room_b])
    teacher_a = teacher_fixture()
    teacher_b = teacher_fixture()

    session_a =
      session_fixture(
        term: term,
        component: component,
        teacher: teacher_a,
        cohorts: [cohort_fixture()]
      )

    session_b =
      session_fixture(
        term: term,
        component: component,
        teacher: teacher_b,
        cohorts: [cohort_fixture()]
      )

    plan = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: plan.id,
      session_id: session_a.id,
      room_id: room_a.id,
      day: 1,
      slot: 1
    })

    placement_fixture(%{
      plan_id: plan.id,
      session_id: session_b.id,
      room_id: room_b.id,
      day: 2,
      slot: 1
    })

    assert {:ok, _plan} = NeuZeit.Planning.publish_plan(plan.id)

    assert {:ok, _move} =
             NeuZeit.Planning.create_schedule_exception(%{
               session_id: session_a.id,
               kind: "move",
               occurrence_date: ~D[2026-08-31],
               new_date: ~D[2026-09-01],
               new_slot: 1,
               new_room_id: room_a.id,
               created_by: "Test administrator",
               reason: "move"
             })

    assert {:error, %{errors: errors}} =
             NeuZeit.Catalog.Sessions.update_generated_session(session_a, %{
               teacher_id: teacher_b.id
             })

    assert Enum.any?(errors, &(&1.type == "teacher_conflict"))
    assert Catalog.get_session!(session_a.id).teacher_id == teacher_a.id
  end

  test "week-mask shrink rejects orphaned active exceptions" do
    term = term_fixture()
    room = room_fixture()
    component = component_fixture(rooms: [room])
    session = session_fixture(term: term, component: component, week_mask: [1, 2])
    plan = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: plan.id,
      session_id: session.id,
      room_id: room.id,
      day: 1,
      slot: 1
    })

    assert {:ok, _plan} = NeuZeit.Planning.publish_plan(plan.id)

    assert {:ok, move} =
             NeuZeit.Planning.create_schedule_exception(%{
               session_id: session.id,
               kind: "move",
               occurrence_date: ~D[2026-09-07],
               new_date: ~D[2026-09-08],
               new_slot: 2,
               new_room_id: room.id,
               created_by: "Test administrator",
               reason: "makeup"
             })

    assert {:error, %{errors: [%{type: "orphaned_exception"} = error]}} =
             NeuZeit.Catalog.Sessions.update_generated_session(session, %{week_mask: [1]})

    assert error.exception_ids == [move.id]
    assert error.occurrence_dates == ["2026-09-07"]
    assert Catalog.get_session!(session.id).week_mask == [1, 2]

    assert {:ok, _reverted} =
             NeuZeit.Planning.update_schedule_exception(move, %{status: "reverted"})

    assert {:ok, _updated} =
             NeuZeit.Catalog.Sessions.update_generated_session(session, %{week_mask: [1]})

    assert Catalog.get_session!(session.id).week_mask == [1]
  end

  test "term date changes reject orphaned active exceptions" do
    term = term_fixture()
    room = room_fixture()
    component = component_fixture(rooms: [room])
    session = session_fixture(term: term, component: component)
    plan = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: plan.id,
      session_id: session.id,
      room_id: room.id,
      day: 1,
      slot: 1
    })

    assert {:ok, _plan} = NeuZeit.Planning.publish_plan(plan.id)

    assert {:ok, move} =
             NeuZeit.Planning.create_schedule_exception(%{
               session_id: session.id,
               kind: "move",
               occurrence_date: ~D[2026-08-31],
               new_date: ~D[2026-09-01],
               new_slot: 2,
               new_room_id: room.id,
               created_by: "Test administrator",
               reason: "move"
             })

    assert {:error, %{errors: errors}} =
             Catalog.update_term(term, %{starts_on: ~D[2026-09-07]})

    assert Enum.any?(errors, fn error ->
             error.type in ["exception_outside_term", "orphaned_exception"] and
               move.id in error.exception_ids
           end)

    assert Catalog.get_term!(term.id).starts_on == ~D[2026-08-31]
  end

  test "excluded dates never carry occurrences: adds are blocked while excluded and conflict-checked after restore" do
    date = ~D[2026-08-31]
    term = term_fixture(excluded_dates: [date])
    room = room_fixture()
    component = component_fixture(rooms: [room])
    session_a = session_fixture(term: term, component: component)
    session_b = session_fixture(term: term, component: component)
    plan = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: plan.id,
      session_id: session_a.id,
      room_id: room.id,
      day: 1,
      slot: 1
    })

    placement_fixture(%{
      plan_id: plan.id,
      session_id: session_b.id,
      room_id: room.id,
      day: 2,
      slot: 1
    })

    assert {:ok, _plan} = NeuZeit.Planning.publish_plan(plan.id)

    addition = %{
      session_id: session_b.id,
      kind: "add",
      occurrence_date: date,
      new_slot: 1,
      new_room_id: room.id,
      created_by: "Test administrator",
      reason: "makeup"
    }

    # After restoring this teaching date, revalidate the newly included meetings.
    assert {:error, %{errors: errors}} = NeuZeit.Planning.create_schedule_exception(addition)
    assert Enum.any?(errors, &(&1.type == "exception_on_excluded_date"))

    assert {:ok, _term} = Catalog.remove_excluded_date(term, date)

    # Once the date is a normal teaching day again, the restored template
    # occurrence protects its cell through the ordinary conflict checks.
    assert {:error, %{errors: errors}} = NeuZeit.Planning.create_schedule_exception(addition)
    assert Enum.any?(errors, &(&1.type == "room_conflict"))
  end

  test "sessions placed in the active plan cannot be deleted" do
    term = term_fixture()
    room = room_fixture()
    component = component_fixture(rooms: [room])
    session = session_fixture(term: term, component: component)
    plan = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: plan.id,
      session_id: session.id,
      room_id: room.id,
      day: 1,
      slot: 1
    })

    assert {:ok, _plan} = NeuZeit.Planning.publish_plan(plan.id)

    assert {:error, {:conflict, _message}} =
             NeuZeit.Catalog.Sessions.delete_generated_session(session)

    assert NeuZeit.Planning.project_active_term(term.id).occurrences != []
  end

  test "sessions placed only in draft plans can still be deleted" do
    term = term_fixture()
    room = room_fixture()
    component = component_fixture(rooms: [room])
    session = session_fixture(term: term, component: component)
    plan = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: plan.id,
      session_id: session.id,
      room_id: room.id,
      day: 1,
      slot: 1
    })

    assert {:ok, _session} = NeuZeit.Catalog.Sessions.delete_generated_session(session)
  end

  test "excluding a date targeted by an active move is rejected" do
    room = room_fixture()
    term = term_fixture(starts_on: ~D[2026-08-31], ends_on: ~D[2026-12-19])
    component = component_fixture(rooms: [room])
    session = session_fixture(term: term, component: component, week_mask: [1, 2])
    plan = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: plan.id,
      session_id: session.id,
      room_id: room.id,
      day: 1,
      slot: 1
    })

    assert {:ok, _plan} = NeuZeit.Planning.publish_plan(plan.id)

    assert {:ok, _exception} =
             NeuZeit.Planning.create_schedule_exception(%{
               session_id: session.id,
               kind: "move",
               occurrence_date: ~D[2026-08-31],
               new_date: ~D[2026-09-08],
               new_slot: 1,
               new_room_id: room.id,
               created_by: "Test administrator",
               reason: "test"
             })

    assert {:error, %{errors: errors}} = Catalog.add_excluded_date(term, ~D[2026-09-08])
    assert Enum.any?(errors, &(&1.type == "exception_on_excluded_date"))

    # A date whose occurrence is merely cancelled may still become excluded:
    # the cancellation is redundant but not contradictory.
    assert {:ok, _exception} =
             NeuZeit.Planning.create_schedule_exception(%{
               session_id: session.id,
               kind: "cancel",
               occurrence_date: ~D[2026-09-07],
               created_by: "Test administrator",
               reason: "test"
             })

    assert {:ok, term} = Catalog.add_excluded_date(term, ~D[2026-09-07])
    assert ~D[2026-09-07] in term.excluded_dates
  end

  test "sessions with active schedule exceptions cannot be deleted" do
    room = room_fixture()
    term = term_fixture(starts_on: ~D[2026-08-31], ends_on: ~D[2026-12-19])
    component = component_fixture(rooms: [room])
    placed_session = session_fixture(term: term, component: component)
    plan = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: plan.id,
      session_id: placed_session.id,
      room_id: room.id,
      day: 1,
      slot: 1
    })

    assert {:ok, _plan} = NeuZeit.Planning.publish_plan(plan.id)

    # A session created after publish is not in the active plan, but its
    # one-off additions are part of the published dated schedule.
    late_session = session_fixture(term: term, component: component)

    assert {:ok, exception} =
             NeuZeit.Planning.create_schedule_exception(%{
               session_id: late_session.id,
               kind: "add",
               occurrence_date: ~D[2026-09-01],
               new_slot: 3,
               new_room_id: room.id,
               created_by: "Test administrator",
               reason: "one-off intro meeting"
             })

    assert {:error, {:conflict, message}} =
             NeuZeit.Catalog.Sessions.delete_generated_session(late_session)

    assert message =~ "active schedule exceptions"

    assert {:ok, _exception} =
             NeuZeit.Planning.update_schedule_exception(exception, %{status: "reverted"})

    assert {:ok, _session} = NeuZeit.Catalog.Sessions.delete_generated_session(late_session)
  end

  test "terms can shrink past weeks used only by archived plans" do
    room = room_fixture()
    term = term_fixture(starts_on: ~D[2026-08-31], ends_on: ~D[2026-12-19])
    component = component_fixture(rooms: [room])
    session = session_fixture(term: term, component: component, week_mask: [1, 10])

    first = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: first.id,
      session_id: session.id,
      room_id: room.id,
      day: 1,
      slot: 1
    })

    assert {:ok, _plan} = NeuZeit.Planning.publish_plan(first.id)

    second = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: second.id,
      session_id: session.id,
      room_id: room.id,
      day: 1,
      slot: 1
    })

    assert {:ok, _plan} = NeuZeit.Planning.publish_plan(second.id)

    # Archived placements keep their dates. Saved teaching load defines current demand.
    [workload] = Catalog.list_workload(term.id)

    assert {:ok, :saved} =
             Catalog.save_workload(term.id, workload, %{week_mask: [1], contact_hours: "2"})

    assert Catalog.get_session!(session.id).week_mask == [1]

    assert {:ok, term} = Catalog.update_term(term, %{ends_on: ~D[2026-09-12]})
    assert term.weeks_count == 2
  end

  test "over-long free text is rejected instead of reaching the database" do
    # A curriculum header pasted into the teacher name reached varchar(255),
    # raised Postgrex.Error and took the LiveView process down with it.
    pasted = String.duplicate("Ministry of Science and Higher Education\t", 40)

    assert {:error, changeset} = Catalog.create_teacher(%{name: pasted})
    assert %{name: ["should be at most 100 character(s)"]} = errors_on(changeset)

    assert {:error, changeset} = Catalog.create_cohort(%{name: pasted})
    assert %{name: ["should be at most 100 character(s)"]} = errors_on(changeset)

    assert {:error, changeset} =
             Catalog.create_course(%{code: pasted, title: pasted})

    assert %{
             code: ["should be at most 50 character(s)"],
             title: ["should be at most 200 character(s)"]
           } = errors_on(changeset)
  end
end
