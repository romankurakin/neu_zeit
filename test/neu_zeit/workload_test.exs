defmodule NeuZeit.WorkloadTest do
  use NeuZeit.DataCase, async: true
  import NeuZeit.Fixtures
  alias NeuZeit.{Catalog, Planning, Repo}
  alias NeuZeit.Catalog.Workload

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
      count: 3
    }

    %{term: term, attrs: attrs, component: component, teacher: teacher}
  end

  test "expands a weekly quantity without choosing placements", ctx do
    assert {:ok, :saved} = Catalog.save_workload(ctx.term.id, nil, ctx.attrs)
    assert [%{count: 3} = row] = Catalog.list_workload(ctx.term.id)
    assert Enum.all?(row.sessions, &(&1.week_mask == [1, 3, 5] && &1.duration_slots == 2))
    assert Repo.aggregate(NeuZeit.Planning.Placement, :count) == 0
  end

  test "quantity edits retain session IDs and avoid duplicate batches", ctx do
    {:ok, :saved} = Catalog.save_workload(ctx.term.id, nil, ctx.attrs)
    [original] = Catalog.list_workload(ctx.term.id)
    ids = Enum.map(original.sessions, & &1.id)
    assert {:ok, :saved} = Catalog.save_workload(ctx.term.id, original, %{ctx.attrs | count: 4})
    [updated] = Catalog.list_workload(ctx.term.id)
    assert Enum.all?(ids, &(&1 in Enum.map(updated.sessions, fn s -> s.id end)))
    assert {:error, %Ecto.Changeset{}} = Catalog.save_workload(ctx.term.id, nil, ctx.attrs)
    assert {:ok, :saved} = Catalog.save_workload(ctx.term.id, updated, %{ctx.attrs | count: 2})
    assert Catalog.count_sessions(ctx.term.id) == 2
  end

  test "rejects stale edits instead of changing a different set of sessions", ctx do
    {:ok, :saved} = Catalog.save_workload(ctx.term.id, nil, ctx.attrs)
    [original] = Catalog.list_workload(ctx.term.id)
    {:ok, _} = Catalog.update_session(original.session, %{duration_slots: 1})
    assert {:error, {:conflict, _}} = Catalog.save_workload(ctx.term.id, original, ctx.attrs)
    assert Catalog.count_sessions(ctx.term.id) == 3
  end

  test "rejects missing groups, invalid quantities and weeks outside the term", ctx do
    for attrs <- [
          %{ctx.attrs | cohort_ids: []},
          %{ctx.attrs | count: 0},
          %{ctx.attrs | count: 10000},
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

  test "existing manually entered sessions appear in workload without migration", ctx do
    first = session_fixture(Map.merge(ctx.attrs, %{term: ctx.term}) |> Map.delete(:count))
    second = session_fixture(Map.merge(ctx.attrs, %{term: ctx.term}) |> Map.delete(:count))
    assert [%{count: 2} = row] = Workload.list(ctx.term.id)
    assert Enum.sort(Enum.map(row.sessions, & &1.id)) == Enum.sort([first.id, second.id])
  end

  test "cannot use a workload from another semester", ctx do
    {:ok, :saved} = Catalog.save_workload(ctx.term.id, nil, ctx.attrs)
    [original] = Catalog.list_workload(ctx.term.id)
    other = term_fixture()
    assert {:error, {:conflict, _}} = Catalog.save_workload(other.id, original, ctx.attrs)
    assert Catalog.count_sessions(other.id) == 0
  end

  test "a batch edit preserves placements when its requirements still fit", ctx do
    {:ok, :saved} = Catalog.save_workload(ctx.term.id, nil, %{ctx.attrs | duration_slots: 1})
    [original] = Catalog.list_workload(ctx.term.id)
    plan = plan_fixture(term: ctx.term)

    {:ok, placement} =
      Planning.create_placement(%{
        plan_id: plan.id,
        session_id: original.session.id,
        room_id: hd(ctx.component.allowed_rooms).id,
        day: 1,
        slot: 1
      })

    assert {:ok, :saved} =
             Catalog.save_workload(ctx.term.id, original, %{
               ctx.attrs
               | duration_slots: 1,
                 count: 4
             })

    assert Enum.any?(Planning.list_placements(plan.id), &(&1.id == placement.id))
  end

  test "reducing a batch retains placed sessions and refuses to remove them", ctx do
    {:ok, :saved} = Catalog.save_workload(ctx.term.id, nil, %{ctx.attrs | duration_slots: 1})
    [original] = Catalog.list_workload(ctx.term.id)
    plan = plan_fixture(term: ctx.term)
    placed = List.last(original.sessions)

    {:ok, placement} =
      Planning.create_placement(%{
        plan_id: plan.id,
        session_id: placed.id,
        room_id: hd(ctx.component.allowed_rooms).id,
        day: 1,
        slot: 1,
        locked: true
      })

    assert {:ok, :saved} =
             Catalog.save_workload(ctx.term.id, original, %{
               ctx.attrs
               | duration_slots: 1,
                 count: 1
             })

    assert [%{session: %{id: id}}] = Catalog.list_workload(ctx.term.id)
    assert id == placed.id
    assert [%{id: placement_id, locked: true}] = Planning.list_placements(plan.id)
    assert placement_id == placement.id
  end

  test "a failed batch update rolls back earlier session and placement changes", ctx do
    {:ok, :saved} =
      Catalog.save_workload(ctx.term.id, nil, %{ctx.attrs | duration_slots: 1, count: 2})

    [original] = Catalog.list_workload(ctx.term.id)
    plan = plan_fixture(term: ctx.term)
    [first, last] = original.sessions

    for {session, slot} <- [{first, 1}, {last, length(NeuZeit.Config.grid!().slots)}] do
      {:ok, _} =
        Planning.create_placement(%{
          plan_id: plan.id,
          session_id: session.id,
          room_id: hd(ctx.component.allowed_rooms).id,
          day: 1,
          slot: slot
        })
    end

    assert {:error, _} = Catalog.save_workload(ctx.term.id, original, %{ctx.attrs | count: 2})
    assert Enum.all?(Catalog.list_sessions(ctx.term.id), &(&1.duration_slots == 1))
    assert Enum.all?(Planning.list_placements(plan.id), &(&1.duration_slots == 1))

    assert {:error, _} =
             Catalog.save_workload(ctx.term.id, original, %{
               ctx.attrs
               | count: 1,
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
             &(&1.session.course_component_id == lab.id &&
                 &1.session.teacher_id == other_teacher.id)
           )

    assert Enum.any?(
             rows,
             &(&1.session.course_component_id == ctx.component.id &&
                 &1.session.teacher_id == ctx.teacher.id)
           )
  end

  test "semester hours generate individual meetings with automatic week selection", ctx do
    attrs = Map.merge(ctx.attrs, %{automatic_weeks: true, contact_hours: "16", duration_slots: 2})
    assert {:ok, :saved} = Catalog.save_workload(ctx.term.id, nil, attrs)
    assert [%{count: 4} = row] = Catalog.list_workload(ctx.term.id)
    assert Enum.all?(row.sessions, & &1.automatic_weeks)
    assert Decimal.equal?(Workload.hours(row), Decimal.new("16"))

    assert {:error, %Ecto.Changeset{}} =
             Catalog.save_workload(ctx.term.id, nil, %{attrs | contact_hours: "1"})
  end

  test "semester demand survives deletion of generated meetings and drives regeneration", ctx do
    attrs = Map.merge(ctx.attrs, %{automatic_weeks: true, contact_hours: "4", duration_slots: 1})
    assert {:ok, :saved} = Catalog.save_workload(ctx.term.id, nil, attrs)
    [row] = Catalog.list_workload(ctx.term.id)
    assert Catalog.merge_candidates(ctx.term.id) == []
    plan = plan_fixture(term: ctx.term)

    assert [%{required_hours: 3.0, planned_hours: 3.0, calendar_hours: +0.0}] =
             NeuZeit.Curriculum.plan_coverage(plan.id)

    for session <- row.sessions, do: assert({:ok, _} = Catalog.delete_session(session))
    assert [%{count: 0} = empty] = Catalog.list_workload(ctx.term.id)
    assert Decimal.equal?(Workload.hours(empty), Decimal.new(4))

    assert [%{required_hours: 3.0, planned_hours: +0.0, calendar_hours: +0.0}] =
             NeuZeit.Curriculum.plan_coverage(plan.id)

    assert {:ok, :ready} = Workload.prepare(ctx.term.id)
    assert [%{count: 2} = restored] = Catalog.list_workload(ctx.term.id)
    assert restored.requirement.id == row.requirement.id
    assert Decimal.equal?(Workload.hours(restored), Decimal.new(4))
  end
end
