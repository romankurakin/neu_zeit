defmodule NeuZeit.PlanningTest do
  use NeuZeit.DataCase, async: false

  import NeuZeit.Fixtures

  alias NeuZeit.Planning

  alias NeuZeit.TestSupport.{
    ConflictingSolver,
    HangingSolver,
    PartialSolver,
    StaleCatalogSolver
  }

  test "allows same room cell when week masks are disjoint" do
    term = term_fixture()
    room = room_fixture()
    component = component_fixture(rooms: [room])
    teacher_a = teacher_fixture()
    teacher_b = teacher_fixture()
    cohort_a = cohort_fixture()
    cohort_b = cohort_fixture()

    session_a =
      session_fixture(
        term: term,
        component: component,
        teacher: teacher_a,
        cohorts: [cohort_a],
        week_mask: [1, 3]
      )

    session_b =
      session_fixture(
        term: term,
        component: component,
        teacher: teacher_b,
        cohorts: [cohort_b],
        week_mask: [2, 4]
      )

    plan = plan_fixture(term: term)

    assert {:ok, _} =
             Planning.create_placement(%{
               plan_id: plan.id,
               session_id: session_a.id,
               room_id: room.id,
               day: 1,
               slot: 1
             })

    assert {:ok, _} =
             Planning.create_placement(%{
               plan_id: plan.id,
               session_id: session_b.id,
               room_id: room.id,
               day: 1,
               slot: 1
             })

    assert Planning.check_plan(plan.id) == []
  end

  test "rejects overlapping room conflicts before insert" do
    term = term_fixture()
    room = room_fixture()
    component = component_fixture(rooms: [room])
    session_a = session_fixture(term: term, component: component, week_mask: [1, 2])
    session_b = session_fixture(term: term, component: component, week_mask: [2, 3])
    plan = plan_fixture(term: term)

    assert {:ok, _} =
             Planning.create_placement(%{
               plan_id: plan.id,
               session_id: session_a.id,
               room_id: room.id,
               day: 1,
               slot: 1
             })

    assert {:error, %{errors: errors}} =
             Planning.create_placement(%{
               plan_id: plan.id,
               session_id: session_b.id,
               room_id: room.id,
               day: 1,
               slot: 1
             })

    assert Enum.any?(errors, &(&1.type == "room_conflict"))
  end

  test "duration reserves every occupied slot and cannot extend past the day" do
    term = term_fixture()
    room = room_fixture()
    component = component_fixture(rooms: [room])

    long =
      session_fixture(
        term: term,
        component: component,
        week_mask: [1],
        duration_slots: 2
      )

    other =
      session_fixture(
        term: term,
        component: component,
        week_mask: [1]
      )

    plan = plan_fixture(term: term)

    assert {:ok, placement} =
             Planning.create_placement(%{
               plan_id: plan.id,
               session_id: long.id,
               room_id: room.id,
               day: 1,
               slot: 1
             })

    assert placement.duration_slots == 2

    assert {:error, %{errors: errors}} =
             Planning.create_placement(%{
               plan_id: plan.id,
               session_id: other.id,
               room_id: room.id,
               day: 1,
               slot: 2
             })

    assert Enum.any?(errors, &(&1.type == "room_conflict"))

    assert {:error, %{errors: bounds_errors}} =
             Planning.update_placement(placement, %{slot: 6})

    assert Enum.any?(bounds_errors, &(&1.type == "grid_bounds"))
  end

  test "duration changes roll back when they create a resource conflict" do
    term = term_fixture()
    room_a = room_fixture(name: "Duration A")
    room_b = room_fixture(name: "Duration B")
    component = component_fixture(rooms: [room_a, room_b])
    cohort = cohort_fixture()

    first = session_fixture(term: term, component: component, cohorts: [cohort])
    second = session_fixture(term: term, component: component, cohorts: [cohort])
    plan = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: plan.id,
      session_id: first.id,
      room_id: room_a.id,
      day: 1,
      slot: 1
    })

    placement_fixture(%{
      plan_id: plan.id,
      session_id: second.id,
      room_id: room_b.id,
      day: 1,
      slot: 2
    })

    assert {:error, %{errors: errors}} =
             NeuZeit.Catalog.update_session(first, %{duration_slots: 2})

    assert Enum.any?(errors, &(&1.type == "cohort_conflict"))
    assert NeuZeit.Catalog.get_session!(first.id).duration_slots == 1
  end

  test "solver refuses non-draft plans" do
    term = term_fixture()
    plan = plan_fixture(term: term, status: "active")

    assert {:error, changeset} = Planning.solve_plan(plan.id)
    assert %{plan_id: ["is read-only unless it is a draft"]} = errors_on(changeset)
  end

  test "solver refuses and does not persist partial solutions" do
    with_solver_adapter(PartialSolver, fn ->
      term = term_fixture()
      room = room_fixture()
      component = component_fixture(rooms: [room])

      unplaced =
        session_fixture(
          term: term,
          component: component,
          teacher: teacher_fixture(),
          cohorts: [cohort_fixture()],
          week_mask: [1, 2],
          sequence_group: "unplaced"
        )

      session_fixture(
        term: term,
        component: component,
        teacher: teacher_fixture(),
        cohorts: [cohort_fixture()],
        week_mask: [1, 2],
        sequence_group: "assigned"
      )

      plan = plan_fixture(term: term)

      assert {:error,
              %{
                errors: [
                  %{
                    type: "unplaced_sessions",
                    session_ids: [session_id],
                    solver_status: "FEASIBLE"
                  }
                ]
              }} = Planning.solve_plan(plan.id)

      assert session_id == unplaced.id
      assert placements_for(plan) == []
    end)
  end

  test "solver results are revalidated against the current plan before persistence" do
    with_solver_adapter(StaleCatalogSolver, fn ->
      try do
        term = term_fixture()
        room = room_fixture()
        component = component_fixture(rooms: [room])

        session_fixture(
          term: term,
          component: component,
          teacher: teacher_fixture(),
          cohorts: [cohort_fixture()],
          week_mask: [1, 2]
        )

        plan = plan_fixture(term: term)

        Application.put_env(:neu_zeit, :stale_solver_callback, fn ->
          session_fixture(
            term: term,
            component: component,
            teacher: teacher_fixture(),
            cohorts: [cohort_fixture()],
            week_mask: [1, 2]
          )
        end)

        assert {:error, %{errors: [%{type: "solver_assignment_mismatch"}]}} =
                 Planning.solve_plan(plan.id)

        assert placements_for(plan) == []
      after
        Application.delete_env(:neu_zeit, :stale_solver_callback)
      end
    end)
  end

  test "rejects a conflicting solver assignment before persistence" do
    with_solver_adapter(ConflictingSolver, fn ->
      term = term_fixture()
      room = room_fixture()
      component = component_fixture(rooms: [room])
      plan = plan_fixture(term: term)

      session_fixture(term: term, component: component, week_mask: [1, 2])
      session_fixture(term: term, component: component, week_mask: [1, 2])

      assert {:error, %{errors: errors}} = Planning.solve_plan(plan.id)
      assert Enum.any?(errors, &(&1.type == "room_conflict"))
      assert placements_for(plan) == []
    end)
  end

  test "clone_plan creates a new draft copy" do
    term = term_fixture()
    source = plan_fixture(term: term, status: "draft")

    assert {:ok, clone} = Planning.clone_plan(source.id)
    assert clone.id != source.id
    assert clone.status == "draft"
    assert clone.name == "#{source.name} copy"
  end

  test "clone_plan refreshes stale placement week masks from sessions" do
    term = term_fixture()
    room = room_fixture()
    component = component_fixture(rooms: [room])
    session = session_fixture(term: term, component: component, week_mask: [1, 2])
    source = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: source.id,
      session_id: session.id,
      room_id: room.id,
      day: 1,
      slot: 1
    })

    assert {:ok, _source} = Planning.publish_plan(source.id)

    replacement = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: replacement.id,
      session_id: session.id,
      room_id: room.id,
      day: 2,
      slot: 1
    })

    assert {:ok, _replacement} = Planning.publish_plan(replacement.id)
    assert {:ok, _session} = NeuZeit.Catalog.update_session(session, %{week_mask: [1, 2, 3]})

    assert {:ok, clone} = Planning.clone_plan(source.id)
    assert [%{week_mask: [1, 2, 3]}] = placements_for(clone)
    assert Planning.check_plan(clone.id) == []
  end

  test "clone_plan rejects archived placements invalidated by current room rules" do
    term = term_fixture()
    old_room = room_fixture()
    current_room = room_fixture()
    component = component_fixture(rooms: [old_room, current_room])
    session = session_fixture(term: term, component: component)
    source = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: source.id,
      session_id: session.id,
      room_id: old_room.id,
      day: 1,
      slot: 1
    })

    assert {:ok, _source} = Planning.publish_plan(source.id)

    replacement = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: replacement.id,
      session_id: session.id,
      room_id: current_room.id,
      day: 2,
      slot: 1
    })

    assert {:ok, _replacement} = Planning.publish_plan(replacement.id)

    # Simulate historical catalog drift without touching the valid active plan.
    NeuZeit.Repo.delete_all(
      from allowed in NeuZeit.Catalog.ComponentAllowedRoom,
        where: allowed.component_id == ^component.id and allowed.room_id == ^old_room.id
    )

    assert {:error, %{errors: errors}} = Planning.clone_plan(source.id)
    assert Enum.any?(errors, &(&1.type == "room_not_allowed"))
    assert Enum.count(Planning.list_plans(), &(&1.term_id == term.id)) == 2
  end

  test "solver task times out instead of blocking forever" do
    spec = %{solver: %{time_limit: 30}}

    assert {:error, %{"status" => "TIMEOUT"}} =
             NeuZeit.Solver.solve(spec, adapter: HangingSolver, timeout: 10, task_timeout: 20)
  end

  test "active plans cannot be deleted" do
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

    assert {:ok, published} = Planning.publish_plan(plan.id)
    assert {:error, {:conflict, _message}} = Planning.delete_plan(published)

    draft = plan_fixture(term: term_fixture())
    assert {:ok, _plan} = Planning.delete_plan(draft)
  end

  test "delete_plan rechecks status on the locked row" do
    plan = plan_fixture()

    plan
    |> Ecto.Changeset.change(status: "active")
    |> NeuZeit.Repo.update!()

    assert {:error, {:conflict, _message}} = Planning.delete_plan(plan)
    assert Planning.get_plan!(plan.id).status == "active"
  end

  test "locked placements can be unlocked and then changed" do
    term = term_fixture()
    room = room_fixture()
    component = component_fixture(rooms: [room])
    session = session_fixture(term: term, component: component)
    plan = plan_fixture(term: term)

    placement =
      placement_fixture(%{
        plan_id: plan.id,
        session_id: session.id,
        room_id: room.id,
        day: 1,
        slot: 1,
        locked: true
      })

    assert {:error, changeset} = Planning.update_placement(placement, %{day: 2})
    assert %{locked: [_message]} = errors_on(changeset)
    assert {:error, _changeset} = Planning.delete_placement(placement)

    assert {:ok, placement} = Planning.update_placement(placement, %{locked: false})
    refute placement.locked
    assert {:ok, _placement} = Planning.delete_placement(placement)
  end

  test "placements cannot escape a published plan by changing plan_id" do
    term = term_fixture()
    room = room_fixture()
    component = component_fixture(rooms: [room])
    session = session_fixture(term: term, component: component)
    active = plan_fixture(term: term)

    placement =
      placement_fixture(%{
        plan_id: active.id,
        session_id: session.id,
        room_id: room.id,
        day: 1,
        slot: 1
      })

    assert {:ok, _active} = Planning.publish_plan(active.id)
    draft = plan_fixture(term: term)

    assert {:error, changeset} = Planning.update_placement(placement, %{plan_id: draft.id})
    assert %{plan_id: ["is read-only"]} = errors_on(changeset)
    assert Planning.get_placement!(placement.id).plan_id == active.id
    assert Planning.project_active_term(term.id).occurrences != []
  end

  test "missing or malformed body ids return validation errors instead of raising" do
    term = term_fixture()
    room = room_fixture()
    plan = plan_fixture(term: term)

    assert {:error, changeset} =
             Planning.create_placement(%{room_id: room.id, day: 1, slot: 1})

    assert %{plan_id: ["can't be blank"]} = errors_on(changeset)

    assert {:error, changeset} =
             Planning.create_placement(%{plan_id: plan.id, room_id: room.id, day: 1, slot: 1})

    assert %{session_id: ["can't be blank"]} = errors_on(changeset)

    assert {:error, changeset} =
             Planning.create_placement(%{plan_id: "abc", room_id: room.id, day: 1, slot: 1})

    assert %{plan_id: ["is invalid"]} = errors_on(changeset)

    assert {:error, changeset} =
             Planning.create_schedule_exception(%{
               kind: "cancel",
               occurrence_date: ~D[2026-08-31],
               reason: "no session"
             })

    assert %{session_id: ["can't be blank"]} = errors_on(changeset)
  end

  test "schedule exceptions validate slot and dates against the grid and term" do
    room = room_fixture()
    term = term_fixture(starts_on: ~D[2026-08-31], ends_on: ~D[2026-12-19])
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

    assert {:ok, _plan} = Planning.publish_plan(plan.id)

    base = %{
      session_id: session.id,
      kind: "move",
      occurrence_date: ~D[2026-08-31],
      new_room_id: room.id,
      reason: "test"
    }

    assert {:error, changeset} =
             Planning.create_schedule_exception(
               Map.merge(base, %{new_date: ~D[2026-09-02], new_slot: 99})
             )

    assert %{new_slot: [message]} = errors_on(changeset)
    assert message =~ "slot grid"

    assert {:error, changeset} =
             Planning.create_schedule_exception(
               Map.merge(base, %{new_date: ~D[2026-09-06], new_slot: 2})
             )

    assert %{new_date: ["must be on a teaching day"]} = errors_on(changeset)

    assert {:error, changeset} =
             Planning.create_schedule_exception(
               Map.merge(base, %{new_date: ~D[2027-01-04], new_slot: 2})
             )

    assert %{new_date: ["must be within the term"]} = errors_on(changeset)

    assert {:ok, _exception} =
             Planning.create_schedule_exception(
               Map.merge(base, %{new_date: ~D[2026-09-02], new_slot: 2})
             )
  end

  test "add exceptions cannot double-book the active schedule" do
    term = term_fixture()
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

    assert {:ok, _plan} = Planning.publish_plan(plan.id)

    # lands on session_a's Monday occurrence in the same room and slot
    assert {:error, %{errors: errors}} =
             Planning.create_schedule_exception(%{
               session_id: session_b.id,
               kind: "add",
               occurrence_date: ~D[2026-08-31],
               new_slot: 1,
               new_room_id: room.id,
               reason: "extra class"
             })

    assert Enum.any?(errors, &(&1.type == "room_conflict"))

    # a free slot on the same day is accepted
    assert {:ok, _exception} =
             Planning.create_schedule_exception(%{
               session_id: session_b.id,
               kind: "add",
               occurrence_date: ~D[2026-08-31],
               new_slot: 2,
               new_room_id: room.id,
               reason: "extra class"
             })
  end

  test "move exceptions validate their target against other occurrences" do
    term = term_fixture()
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

    assert {:ok, _plan} = Planning.publish_plan(plan.id)

    # moving session_a's Monday occurrence onto session_b's Tuesday cell collides
    assert {:error, %{errors: errors}} =
             Planning.create_schedule_exception(%{
               session_id: session_a.id,
               kind: "move",
               occurrence_date: ~D[2026-08-31],
               new_date: ~D[2026-09-01],
               new_slot: 1,
               new_room_id: room.id,
               reason: "clash"
             })

    assert Enum.any?(errors, &(&1.type == "room_conflict"))

    # moving to a free cell on the same day works
    assert {:ok, _exception} =
             Planning.create_schedule_exception(%{
               session_id: session_a.id,
               kind: "move",
               occurrence_date: ~D[2026-08-31],
               new_date: ~D[2026-09-01],
               new_slot: 3,
               new_room_id: room.id,
               reason: "makeup"
             })
  end

  test "move and add exceptions reject rooms not allowed by their component" do
    term = term_fixture()
    allowed_room = room_fixture()
    disallowed_room = room_fixture()
    component = component_fixture(rooms: [allowed_room])
    session = session_fixture(term: term, component: component)
    plan = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: plan.id,
      session_id: session.id,
      room_id: allowed_room.id,
      day: 1,
      slot: 1
    })

    assert {:ok, _plan} = Planning.publish_plan(plan.id)

    for kind <- ["move", "add"] do
      assert {:error, %{errors: errors}} =
               Planning.create_schedule_exception(%{
                 session_id: session.id,
                 kind: kind,
                 occurrence_date: ~D[2026-08-31],
                 new_date: ~D[2026-09-01],
                 new_slot: 2,
                 new_room_id: disallowed_room.id,
                 reason: "invalid room"
               })

      assert Enum.any?(errors, &(&1.type == "room_not_allowed"))
    end
  end

  test "exception term and session ownership are immutable" do
    term_a = term_fixture()
    term_b = term_fixture()
    room_a = room_fixture()
    room_b = room_fixture()
    session_a = session_fixture(term: term_a, component: component_fixture(rooms: [room_a]))
    session_b = session_fixture(term: term_b, component: component_fixture(rooms: [room_b]))

    assert {:ok, addition} =
             Planning.create_schedule_exception(%{
               session_id: session_a.id,
               kind: "add",
               occurrence_date: ~D[2026-09-02],
               new_slot: 4,
               new_room_id: room_a.id,
               reason: "extra"
             })

    assert {:error, changeset} =
             Planning.update_schedule_exception(addition, %{
               term_id: term_b.id,
               session_id: session_b.id
             })

    assert %{term_id: ["is read-only"], session_id: ["is read-only"]} = errors_on(changeset)
    persisted = Planning.get_schedule_exception!(addition.id)
    assert {persisted.term_id, persisted.session_id} == {term_a.id, session_a.id}
  end

  test "move and cancel exceptions must match a template occurrence" do
    term = term_fixture()
    room = room_fixture()
    component = component_fixture(rooms: [room])
    session = session_fixture(term: term, component: component, week_mask: [1])
    plan = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: plan.id,
      session_id: session.id,
      room_id: room.id,
      day: 1,
      slot: 1
    })

    assert {:ok, _plan} = Planning.publish_plan(plan.id)

    assert {:error, changeset} =
             Planning.create_schedule_exception(%{
               session_id: session.id,
               kind: "move",
               occurrence_date: ~D[2026-09-01],
               new_date: ~D[2026-09-02],
               new_slot: 2,
               new_room_id: room.id,
               reason: "wrong weekday"
             })

    assert %{occurrence_date: ["does not match any scheduled occurrence"]} =
             errors_on(changeset)

    assert {:error, changeset} =
             Planning.create_schedule_exception(%{
               session_id: session.id,
               kind: "cancel",
               occurrence_date: ~D[2026-09-07],
               reason: "off week"
             })

    assert %{occurrence_date: ["does not match any scheduled occurrence"]} =
             errors_on(changeset)
  end

  test "reverting or deleting a cancellation validates restored occurrences" do
    term = term_fixture()
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

    assert {:ok, _plan} = Planning.publish_plan(plan.id)

    assert {:ok, cancellation} =
             Planning.create_schedule_exception(%{
               session_id: session_a.id,
               kind: "cancel",
               occurrence_date: ~D[2026-08-31],
               reason: "cancelled"
             })

    assert {:ok, addition} =
             Planning.create_schedule_exception(%{
               session_id: session_b.id,
               kind: "add",
               occurrence_date: ~D[2026-08-31],
               new_slot: 1,
               new_room_id: room.id,
               reason: "replacement"
             })

    assert {:error, %{errors: errors}} =
             Planning.update_schedule_exception(cancellation, %{status: "reverted"})

    assert Enum.any?(errors, &(&1.type == "room_conflict"))
    assert Planning.get_schedule_exception!(cancellation.id).status == "active"

    assert {:error, %{errors: delete_errors}} =
             Planning.delete_schedule_exception(cancellation)

    assert Enum.any?(delete_errors, &(&1.type == "room_conflict"))

    assert {:ok, _addition} = Planning.delete_schedule_exception(addition)

    assert {:ok, reverted} =
             Planning.update_schedule_exception(cancellation, %{status: "reverted"})

    assert reverted.status == "reverted"
  end

  test "publishing validates existing additions against the candidate plan" do
    term = term_fixture()
    room = room_fixture()
    component = component_fixture(rooms: [room])
    session_a = session_fixture(term: term, component: component)
    session_b = session_fixture(term: term, component: component)
    active = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: active.id,
      session_id: session_a.id,
      room_id: room.id,
      day: 1,
      slot: 1
    })

    placement_fixture(%{
      plan_id: active.id,
      session_id: session_b.id,
      room_id: room.id,
      day: 2,
      slot: 1
    })

    assert {:ok, _active} = Planning.publish_plan(active.id)

    assert {:ok, addition} =
             Planning.create_schedule_exception(%{
               session_id: session_a.id,
               kind: "add",
               occurrence_date: ~D[2026-09-02],
               new_slot: 2,
               new_room_id: room.id,
               reason: "extra class"
             })

    candidate = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: candidate.id,
      session_id: session_a.id,
      room_id: room.id,
      day: 4,
      slot: 1
    })

    placement_fixture(%{
      plan_id: candidate.id,
      session_id: session_b.id,
      room_id: room.id,
      day: 3,
      slot: 2
    })

    assert {:error, %{errors: errors}} = Planning.publish_plan(candidate.id)
    assert Enum.any?(errors, &(&1.type == "room_conflict" and addition.id in &1.exception_ids))

    assert {:ok, _reverted} =
             Planning.update_schedule_exception(addition, %{status: "reverted"})

    assert {:ok, published} = Planning.publish_plan(candidate.id)
    assert published.status == "active"
  end

  test "publishing rejects moves orphaned by the candidate plan" do
    term = term_fixture()
    room = room_fixture()
    component = component_fixture(rooms: [room])
    session = session_fixture(term: term, component: component)
    active = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: active.id,
      session_id: session.id,
      room_id: room.id,
      day: 1,
      slot: 1
    })

    assert {:ok, _active} = Planning.publish_plan(active.id)

    assert {:ok, move} =
             Planning.create_schedule_exception(%{
               session_id: session.id,
               kind: "move",
               occurrence_date: ~D[2026-08-31],
               new_date: ~D[2026-09-02],
               new_slot: 2,
               new_room_id: room.id,
               reason: "makeup"
             })

    candidate = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: candidate.id,
      session_id: session.id,
      room_id: room.id,
      day: 2,
      slot: 1
    })

    assert {:error, %{errors: [%{type: "orphaned_exception"} = error]}} =
             Planning.publish_plan(candidate.id)

    assert error.exception_ids == [move.id]

    assert {:ok, _reverted} = Planning.update_schedule_exception(move, %{status: "reverted"})
    assert {:ok, published} = Planning.publish_plan(candidate.id)
    assert published.status == "active"
  end

  test "schedule exceptions respect duration bounds and the session slot profile" do
    term = term_fixture()
    room = room_fixture()
    component = component_fixture(rooms: [room])

    profile =
      slot_profile_fixture(
        term: term,
        cells: [%{day: 1, slot: 1}, %{day: 1, slot: 5}]
      )

    session =
      session_fixture(
        term: term,
        component: component,
        slot_profile_id: profile.id,
        duration_slots: 2,
        week_mask: [1]
      )

    plan = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: plan.id,
      session_id: session.id,
      room_id: room.id,
      day: 1,
      slot: 1
    })

    assert {:ok, _plan} = Planning.publish_plan(plan.id)

    base = %{
      session_id: session.id,
      kind: "move",
      occurrence_date: ~D[2026-08-31],
      new_date: ~D[2026-08-31],
      new_room_id: room.id,
      reason: "move a double period"
    }

    assert {:error, changeset} =
             Planning.create_schedule_exception(Map.put(base, :new_slot, 6))

    assert %{new_slot: [_message]} = errors_on(changeset)

    assert {:error, %{errors: errors}} =
             Planning.create_schedule_exception(Map.put(base, :new_slot, 2))

    assert Enum.any?(errors, &(&1.type == "time_not_allowed"))

    assert {:ok, exception} =
             Planning.create_schedule_exception(Map.put(base, :new_slot, 5))

    assert exception.new_slot == 5
  end

  defp placements_for(plan) do
    Enum.filter(Planning.list_placements(), &(&1.plan_id == plan.id))
  end

  defp with_solver_adapter(adapter, fun) do
    previous = Application.get_env(:neu_zeit, :solver_adapter)
    Application.put_env(:neu_zeit, :solver_adapter, adapter)

    try do
      fun.()
    after
      if previous do
        Application.put_env(:neu_zeit, :solver_adapter, previous)
      else
        Application.delete_env(:neu_zeit, :solver_adapter)
      end
    end
  end
end
