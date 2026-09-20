defmodule NeuZeit.WorkloadTest do
  use NeuZeit.DataCase, async: true
  import NeuZeit.Fixtures
  alias NeuZeit.{Catalog, Planning, Repo}
  alias NeuZeit.Catalog.Workloads

  setup do
    term = term_fixture()
    component = component_fixture()
    teacher = teacher_fixture()
    cohort = cohort_fixture()

    attrs = %{
      course_component_id: component.id,
      teacher_id: teacher.id,
      cohort_ids: [cohort.id],
      week_mask: [1, 3, 5],
      duration_slots: 2,
      contact_hours: "12"
    }

    %{term: term, attrs: attrs, component: component, teacher: teacher}
  end

  test "expands semester hours into a repeating series without choosing placements", ctx do
    assert {:ok, :saved} = Catalog.save_workload(ctx.term.id, nil, ctx.attrs)
    assert [row] = Catalog.list_workload(ctx.term.id)
    assert Workloads.series_count(row) == 1
    assert Enum.all?(row.sessions, &(&1.week_mask == [1, 3, 5] && &1.duration_slots == 2))
    refute Enum.any?(row.sessions, & &1.automatic_weeks)
    assert Repo.aggregate(NeuZeit.Planning.Placement, :count) == 0
  end

  test "hour edits retain session IDs and avoid duplicate batches", ctx do
    {:ok, :saved} = create_legacy_workload(ctx.term.id, ctx.attrs)
    [original] = Catalog.list_workload(ctx.term.id)
    ids = Enum.map(original.sessions, & &1.id)

    assert {:ok, :saved} =
             Catalog.save_workload(ctx.term.id, original, %{ctx.attrs | contact_hours: "16"})

    [updated] = Catalog.list_workload(ctx.term.id)
    assert Enum.all?(ids, &(&1 in Enum.map(updated.sessions, fn s -> s.id end)))
    assert {:error, %Ecto.Changeset{}} = Catalog.save_workload(ctx.term.id, nil, ctx.attrs)

    assert {:ok, :saved} =
             Catalog.save_workload(ctx.term.id, updated, %{ctx.attrs | contact_hours: "8"})

    assert Catalog.count_sessions(ctx.term.id) == 2
  end

  test "rejects stale edits instead of changing a different set of sessions", ctx do
    {:ok, :saved} = create_legacy_workload(ctx.term.id, ctx.attrs)
    [original] = Catalog.list_workload(ctx.term.id)

    {:ok, _} =
      NeuZeit.Catalog.Sessions.update_generated_session(hd(original.sessions), %{
        duration_slots: 1
      })

    assert {:error, {:conflict, _}} = Catalog.save_workload(ctx.term.id, original, ctx.attrs)
    assert Catalog.count_sessions(ctx.term.id) == 3
  end

  test "rejects missing groups, invalid quantities and weeks outside the term", ctx do
    for attrs <- [
          %{ctx.attrs | cohort_ids: []},
          %{ctx.attrs | contact_hours: "0"},
          %{ctx.attrs | contact_hours: "40000"},
          %{ctx.attrs | week_mask: [999]}
        ] do
      assert {:error, %Ecto.Changeset{}} = Catalog.save_workload(ctx.term.id, nil, attrs)
      assert Catalog.count_sessions(ctx.term.id) == 0
    end
  end

  test "an invalid availability constraint rolls back the whole expansion", ctx do
    {:ok, _} =
      Catalog.replace_teacher_availability(ctx.term.id, ctx.teacher.id, [%{day: 1, slot: 1}])

    assert {:error, %Ecto.Changeset{}} = Catalog.save_workload(ctx.term.id, nil, ctx.attrs)
    assert Catalog.count_sessions(ctx.term.id) == 0
  end

  test "fixed repetitions have saved hours and preparation keeps their dates", ctx do
    session = session_fixture(Map.merge(ctx.attrs, %{term: ctx.term}))
    assert [row] = Workloads.list(ctx.term.id)
    assert row.id == session.workload_id
    assert Decimal.equal?(row.requirement.contact_hours, 12)
    assert {:ok, :ready} = Workloads.prepare(ctx.term.id)
    assert [retained] = Catalog.list_sessions(ctx.term.id)
    assert retained.id == session.id
    assert retained.week_mask == [1, 3, 5]
    refute retained.automatic_weeks
  end

  test "cannot use a workload from another semester", ctx do
    {:ok, :saved} = Catalog.save_workload(ctx.term.id, nil, ctx.attrs)
    [original] = Catalog.list_workload(ctx.term.id)
    other = term_fixture()
    assert {:error, changeset} = Catalog.save_workload(other.id, original, ctx.attrs)
    assert errors_on(changeset).term_id == ["is invalid"]
    assert Catalog.count_sessions(other.id) == 0
  end

  test "a batch edit preserves placements when its requirements still fit", ctx do
    {:ok, :saved} = create_legacy_workload(ctx.term.id, %{ctx.attrs | duration_slots: 1})
    [original] = Catalog.list_workload(ctx.term.id)
    plan = plan_fixture(term: ctx.term)

    {:ok, placement} =
      Planning.create_placement(%{
        plan_id: plan.id,
        session_id: hd(original.sessions).id,
        room_id: hd(ctx.component.allowed_rooms).id,
        week_mask: [1],
        day: 1,
        slot: 1
      })

    [original] = Catalog.list_workload(ctx.term.id)

    assert {:ok, :saved} =
             Catalog.save_workload(ctx.term.id, original, %{
               ctx.attrs
               | duration_slots: 1,
                 contact_hours: "8"
             })

    assert Enum.any?(Planning.list_placements(plan.id), &(&1.id == placement.id))
  end

  test "reducing a batch retains placed sessions and refuses to remove them", ctx do
    {:ok, :saved} = create_legacy_workload(ctx.term.id, %{ctx.attrs | duration_slots: 1})
    [original] = Catalog.list_workload(ctx.term.id)
    plan = plan_fixture(term: ctx.term)
    placed = List.last(original.sessions)

    {:ok, placement} =
      Planning.create_placement(%{
        plan_id: plan.id,
        session_id: placed.id,
        room_id: hd(ctx.component.allowed_rooms).id,
        week_mask: [1],
        day: 1,
        slot: 1,
        locked: true
      })

    [original] = Catalog.list_workload(ctx.term.id)

    assert {:ok, :saved} =
             Catalog.save_workload(ctx.term.id, original, %{
               ctx.attrs
               | duration_slots: 1,
                 contact_hours: "2"
             })

    assert [%{sessions: [%{id: id}]}] = Catalog.list_workload(ctx.term.id)
    assert id == placed.id
    assert [%{id: placement_id, locked: true}] = Planning.list_placements(plan.id)
    assert placement_id == placement.id
  end

  test "a failed batch update rolls back earlier session and placement changes", ctx do
    {:ok, :saved} =
      create_legacy_workload(ctx.term.id, %{ctx.attrs | duration_slots: 1, contact_hours: "4"})

    [original] = Catalog.list_workload(ctx.term.id)
    plan = plan_fixture(term: ctx.term)
    [first, last] = original.sessions

    for {session, slot} <- [{first, 1}, {last, length(NeuZeit.Config.grid!().slots)}] do
      {:ok, _} =
        Planning.create_placement(%{
          plan_id: plan.id,
          session_id: session.id,
          room_id: hd(ctx.component.allowed_rooms).id,
          week_mask: [1],
          day: 1,
          slot: slot
        })
    end

    [original] = Catalog.list_workload(ctx.term.id)

    assert {:error, _} =
             Catalog.save_workload(ctx.term.id, original, %{ctx.attrs | contact_hours: "8"})

    assert Enum.all?(Catalog.list_sessions(ctx.term.id), &(&1.duration_slots == 1))
    assert Enum.all?(Planning.list_placements(plan.id), &(&1.duration_slots == 1))

    assert {:error, _} =
             Catalog.save_workload(ctx.term.id, original, %{
               ctx.attrs
               | contact_hours: "2",
                 duration_slots: 1
             })

    assert Catalog.count_sessions(ctx.term.id) == 2
  end

  test "different teaching types of one course can have different teachers", ctx do
    lab = component_fixture(course: ctx.component.course, kind: "lab")
    other_teacher = teacher_fixture()
    assert {:ok, :saved} = Catalog.save_workload(ctx.term.id, nil, ctx.attrs)

    assert {:ok, :saved} =
             Catalog.save_workload(ctx.term.id, nil, %{
               ctx.attrs
               | course_component_id: lab.id,
                 teacher_id: other_teacher.id
             })

    rows = Catalog.list_workload(ctx.term.id)
    assert length(rows) == 2

    assert Enum.any?(
             rows,
             &(&1.requirement.course_component_id == lab.id &&
                 &1.requirement.teacher_id == other_teacher.id)
           )

    assert Enum.any?(
             rows,
             &(&1.requirement.course_component_id == ctx.component.id &&
                 &1.requirement.teacher_id == ctx.teacher.id)
           )
  end

  test "semester hours generate individual meetings with automatic week selection", ctx do
    attrs = Map.merge(ctx.attrs, %{automatic_weeks: true, contact_hours: "16", duration_slots: 2})
    assert {:ok, :saved} = create_legacy_workload(ctx.term.id, attrs)
    assert [row] = Catalog.list_workload(ctx.term.id)
    assert Workloads.series_count(row) == 4
    assert Enum.all?(row.sessions, & &1.automatic_weeks)
    assert Decimal.equal?(Workloads.hours(row), Decimal.new("16"))

    assert {:ok, :saved} =
             Catalog.save_workload(ctx.term.id, row, %{attrs | contact_hours: "1"})

    [reduced] = Catalog.list_workload(ctx.term.id)
    assert Workloads.series_count(reduced) == 1
    assert Decimal.equal?(Workloads.hours(reduced), Decimal.new("1"))
  end

  test "semester demand survives deletion of generated meetings and drives regeneration", ctx do
    attrs = Map.merge(ctx.attrs, %{automatic_weeks: true, contact_hours: "4", duration_slots: 1})
    assert {:ok, :saved} = create_legacy_workload(ctx.term.id, attrs)
    [row] = Catalog.list_workload(ctx.term.id)
    assert Catalog.merge_candidates(ctx.term.id) == []
    plan = plan_fixture(term: ctx.term)

    assert [%{required_hours: 3.0, planned_hours: 3.0, calendar_hours: +0.0}] =
             NeuZeit.Curriculum.plan_coverage(plan.id)

    for session <- row.sessions,
        do: assert({:ok, _} = NeuZeit.Catalog.Sessions.delete_generated_session(session))

    assert [empty] = Catalog.list_workload(ctx.term.id)

    assert Workloads.series_count(empty) == 0
    assert Decimal.equal?(Workloads.hours(empty), Decimal.new(4))

    assert [%{required_hours: 3.0, planned_hours: +0.0, calendar_hours: +0.0}] =
             NeuZeit.Curriculum.plan_coverage(plan.id)

    assert [%{required_hours: 3.0, scheduled_hours: +0.0, status: :under}] =
             NeuZeit.Curriculum.term_coverage(ctx.term.id)

    assert {:ok, :ready} = Workloads.prepare(ctx.term.id)
    assert [restored] = Catalog.list_workload(ctx.term.id)
    assert Workloads.series_count(restored) == 2
    assert restored.requirement.id == row.requirement.id
    assert Decimal.equal?(Workloads.hours(restored), Decimal.new(4))
  end

  test "individual session writes and count-only workloads are refused", ctx do
    assert {:error, _} =
             Catalog.save_workload(
               ctx.term.id,
               nil,
               ctx.attrs |> Map.delete(:contact_hours) |> Map.put(:count, 3)
             )

    assert {:error, {:conflict, _}} =
             Catalog.create_session(Map.put(ctx.attrs, :term_id, ctx.term.id))

    assert {:ok, :saved} =
             Catalog.save_workload(ctx.term.id, nil, Map.put(ctx.attrs, :automatic_weeks, true))

    [row] = Catalog.list_workload(ctx.term.id)
    refute Enum.any?(row.sessions, & &1.automatic_weeks)
    session = hd(row.sessions)
    assert {:error, {:conflict, _}} = Catalog.update_session(session, %{duration_slots: 1})
    assert {:error, {:conflict, _}} = Catalog.delete_session(session)
    assert Catalog.get_session!(session.id).duration_slots == 2
  end

  test "preparation repairs all generated metadata even when the count matches", ctx do
    assert {:ok, :saved} = create_legacy_workload(ctx.term.id, ctx.attrs)
    [row] = Catalog.list_workload(ctx.term.id)
    session = hd(row.sessions)
    teacher = teacher_fixture()
    group = cohort_fixture()
    component = component_fixture()
    profile = slot_profile_fixture(term: ctx.term)

    Repo.update_all(from(s in NeuZeit.Catalog.Session, where: s.id == ^session.id),
      set: [
        duration_slots: 1,
        teacher_id: teacher.id,
        course_component_id: component.id,
        slot_profile_id: profile.id,
        week_mask: [2],
        sequence_group: "changed",
        automatic_weeks: false
      ]
    )

    Repo.delete_all(
      from(sc in NeuZeit.Catalog.SessionCohort, where: sc.session_id == ^session.id)
    )

    Repo.insert!(%NeuZeit.Catalog.SessionCohort{session_id: session.id, cohort_id: group.id})
    assert {:error, {:conflict, _}} = Workloads.check(ctx.term.id)
    plan = plan_fixture(term: ctx.term)
    assert {:error, {:conflict, _}} = Planning.publish_plan(plan.id)
    assert {:ok, :ready} = Workloads.prepare(ctx.term.id)
    assert :ok = Workloads.check(ctx.term.id)
    repaired = Catalog.get_session!(session.id)
    assert repaired.teacher_id == ctx.attrs.teacher_id
    assert repaired.course_component_id == ctx.attrs.course_component_id
    assert repaired.slot_profile_id == nil
    assert repaired.duration_slots == 2
    assert repaired.automatic_weeks
    assert repaired.week_mask == [1, 3, 5]
    assert repaired.sequence_group == nil
    assert Enum.map(repaired.cohorts, & &1.id) == ctx.attrs.cohort_ids
    assert [updated] = Catalog.list_workload(ctx.term.id)
    assert updated.id == row.id
    assert Enum.map(updated.sessions, & &1.id) == Enum.map(row.sessions, & &1.id)
  end

  test "missing generated meetings block publication and keep the workload address", ctx do
    assert {:ok, :saved} = create_legacy_workload(ctx.term.id, ctx.attrs)
    [row] = Catalog.list_workload(ctx.term.id)
    for session <- row.sessions, do: Repo.delete!(session)
    plan = plan_fixture(term: ctx.term)
    assert {:error, {:conflict, _}} = Planning.publish_plan(plan.id)
    assert {:error, _} = Catalog.update_term(ctx.term, %{ends_on: ~D[2026-09-12]})
    assert [empty] = Catalog.list_workload(ctx.term.id)
    assert empty.id == row.id
    assert {:ok, :ready} = Workloads.prepare(ctx.term.id)
    assert [restored] = Catalog.list_workload(ctx.term.id)
    assert restored.id == row.id
    assert Workloads.series_count(restored) == 3
  end

  test "deleting workload removes its meetings but refuses any placed meeting", ctx do
    assert {:ok, :saved} = create_legacy_workload(ctx.term.id, ctx.attrs)
    [row] = Catalog.list_workload(ctx.term.id)
    plan = plan_fixture(term: ctx.term)

    placement =
      placement_fixture(
        plan_id: plan.id,
        session_id: hd(row.sessions).id,
        room_id: hd(ctx.component.allowed_rooms).id,
        day: 1,
        slot: 1,
        week_mask: [1]
      )

    [row] = Catalog.list_workload(ctx.term.id)
    assert {:error, {:conflict, _}} = Catalog.delete_workload(ctx.term.id, row)
    assert {:ok, _} = Planning.delete_placement(placement)
    [row] = Catalog.list_workload(ctx.term.id)
    assert {:ok, :deleted} = Catalog.delete_workload(ctx.term.id, row)
    assert Catalog.list_workload(ctx.term.id) == []
    assert Catalog.list_sessions(ctx.term.id) == []
  end

  # Existing automatic workloads retain their solver-selected weeks. New public
  # creation is covered separately and always creates repeating series.
  defp create_legacy_workload(term_id, attrs) do
    session =
      session_fixture(
        Map.merge(attrs, %{
          term: Catalog.get_term!(term_id),
          automatic_weeks: true
        })
      )

    row = Enum.find(Catalog.list_workload(term_id), &(&1.id == session.workload_id))
    Catalog.save_workload(term_id, row, attrs)
  end
end
