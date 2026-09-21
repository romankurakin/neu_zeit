defmodule NeuZeit.WorkloadSeriesTest do
  use NeuZeit.DataCase, async: true
  import NeuZeit.Fixtures

  alias NeuZeit.{Catalog, Planning, Repo}
  alias NeuZeit.Catalog.{Sessions, Workload, Workloads}
  alias NeuZeit.Solver.SpecBuilder

  setup do
    term = term_fixture(starts_on: ~D[2026-08-31], ends_on: ~D[2026-12-12])
    assert term.weeks_count == 15
    component = component_fixture()
    teacher = teacher_fixture()
    cohort = cohort_fixture()

    attrs = %{
      course_component_id: component.id,
      teacher_id: teacher.id,
      cohort_ids: [cohort.id],
      week_mask: Enum.to_list(1..15),
      duration_slots: 1,
      contact_hours: "45"
    }

    %{term: term, component: component, teacher: teacher, cohort: cohort, attrs: attrs}
  end

  test "45 required hours produce two recurring series and 46 planned hours", c do
    assert {:ok, :saved} = Catalog.save_workload(c.term.id, nil, c.attrs)
    [row] = Workloads.list(c.term.id)

    assert Decimal.equal?(row.requirement.contact_hours, 45)
    assert Decimal.equal?(Workloads.planned_hours(row, c.term), 46)
    assert Workloads.meeting_count(row) == 23
    assert length(row.sessions) == 2
    assert masks(row) == Enum.sort([Enum.to_list(1..15), Enum.to_list(1..15//2)])
    refute Enum.any?(row.sessions, & &1.automatic_weeks)
    assert :ok = Workloads.check(c.term.id)
    assert {:ok, :ready} = Workloads.prepare(c.term.id)

    assert Enum.map(hd(Workloads.list(c.term.id)).sessions, & &1.id) ==
             Enum.map(row.sessions, & &1.id)
  end

  test "rounding down preserves the requirement and survives preparation", c do
    assert {:ok, :saved} =
             Catalog.save_workload(c.term.id, nil, Map.put(c.attrs, :rounding_mode, "down"))

    [row] = Workloads.list(c.term.id)
    assert Decimal.equal?(row.requirement.contact_hours, 45)
    assert Decimal.equal?(Workloads.planned_hours(row, c.term), 44)
    assert Workloads.meeting_count(row) == 22
    assert Enum.to_list(2..14//2) in masks(row)
    ids = Enum.map(row.sessions, & &1.id)

    assert {:ok, :ready} = Workloads.prepare(c.term.id)
    [prepared] = Workloads.list(c.term.id)
    assert Enum.map(prepared.sessions, & &1.id) == ids
    assert Decimal.equal?(Workloads.planned_hours(prepared, c.term), 44)
  end

  test "a positive requirement below one meeting never produces an empty workload", c do
    attrs = Map.merge(c.attrs, %{contact_hours: "1", duration_slots: 2, rounding_mode: "down"})
    assert {:ok, :saved} = Catalog.save_workload(c.term.id, nil, attrs)
    [row] = Workloads.list(c.term.id)
    assert Workloads.meeting_count(row) == 1
    assert Decimal.equal?(row.requirement.contact_hours, 1)
    assert Decimal.equal?(Workloads.planned_hours(row, c.term), 4)
  end

  test "fractional meeting hours use the semester unit without a divisibility restriction", c do
    term = term_fixture(academic_hour_minutes: 60)
    attrs = %{c.attrs | contact_hours: "4", week_mask: [1, 2, 3]}
    assert {:ok, :saved} = Catalog.save_workload(term.id, nil, attrs)
    [row] = Workloads.list(term.id)
    assert Workloads.meeting_count(row) == 3
    assert Decimal.equal?(Workloads.planned_hours(row, term), Decimal.new("4.5"))
    assert Decimal.equal?(row.requirement.contact_hours, 4)
  end

  test "parity is term-relative and can change without changing required hours", c do
    attrs = %{c.attrs | contact_hours: "6", week_mask: Enum.to_list(3..8)}
    assert {:ok, :saved} = Catalog.save_workload(c.term.id, nil, attrs)
    [odd] = Workloads.list(c.term.id)
    assert masks(odd) == [[3, 5, 7]]

    assert {:ok, :saved} =
             Catalog.save_workload(c.term.id, odd, %{remainder_parity: "even"})

    [even] = Workloads.list(c.term.id)
    assert masks(even) == [[4, 6, 8]]
    assert Decimal.equal?(even.requirement.contact_hours, 6)
    assert {:ok, :ready} = Workloads.prepare(c.term.id)
    assert masks(hd(Workloads.list(c.term.id))) == [[4, 6, 8]]
  end

  test "a centered remainder preserves its requested count", c do
    assert {:ok, :saved} =
             Catalog.save_workload(c.term.id, nil, %{c.attrs | contact_hours: "10"})

    assert masks(hd(Workloads.list(c.term.id))) == [[2, 5, 8, 11, 14]]
  end

  test "valid manually split series survive preparation and resource-only edits", c do
    assert {:ok, :saved} =
             Catalog.save_workload(c.term.id, nil, %{c.attrs | contact_hours: "30"})

    [row] = Workloads.list(c.term.id)
    [series] = row.sessions

    assert {:ok, first} =
             Sessions.update_generated_session(series, %{week_mask: Enum.to_list(1..7)})

    assert {:ok, second} =
             Sessions.create_generated_session(
               row.id,
               Map.merge(c.attrs, %{
                 term_id: c.term.id,
                 automatic_weeks: false,
                 week_mask: Enum.to_list(8..15)
               })
             )

    assert :ok = Workloads.check(c.term.id)
    assert {:ok, :ready} = Workloads.prepare(c.term.id)
    [split] = Workloads.list(c.term.id)
    assert Enum.sort(Enum.map(split.sessions, & &1.id)) == Enum.sort([first.id, second.id])
    original_masks = masks(split)

    assert {:ok, :saved} = Catalog.save_workload(c.term.id, split, %{})
    [unchanged] = Workloads.list(c.term.id)
    teacher = teacher_fixture()
    assert {:ok, :saved} = Catalog.save_workload(c.term.id, unchanged, %{teacher_id: teacher.id})
    [updated] = Workloads.list(c.term.id)
    assert masks(updated) == original_masks
    assert Enum.sort(Enum.map(updated.sessions, & &1.id)) == Enum.sort([first.id, second.id])
    assert Enum.all?(updated.sessions, &(&1.teacher_id == teacher.id))
  end

  test "a manually changed mask outside allowed weeks is not synchronized", c do
    attrs = %{c.attrs | contact_hours: "4", week_mask: [1, 2]}
    assert {:ok, :saved} = Catalog.save_workload(c.term.id, nil, attrs)
    [row] = Workloads.list(c.term.id)
    assert {:ok, _} = Sessions.update_generated_session(hd(row.sessions), %{week_mask: [1, 3]})
    assert {:error, {:conflict, _}} = Workloads.check(c.term.id)
  end

  test "stale rounding and parity edits are rejected even when series do not change", c do
    assert {:ok, :saved} =
             Catalog.save_workload(c.term.id, nil, %{c.attrs | contact_hours: "30"})

    for policy <- [%{rounding_mode: "down"}, %{remainder_parity: "even"}] do
      [before] = Workloads.list(c.term.id)
      ids = Enum.map(before.sessions, & &1.id)
      assert {:ok, :saved} = Catalog.save_workload(c.term.id, before, policy)
      [after_edit] = Workloads.list(c.term.id)
      assert Enum.map(after_edit.sessions, & &1.id) == ids
      assert {:error, {:conflict, _}} = Catalog.save_workload(c.term.id, before, %{})
    end
  end

  test "reducing identical full series retains the one with historical exceptions", c do
    assert {:ok, :saved} =
             Catalog.save_workload(c.term.id, nil, %{c.attrs | contact_hours: "60"})

    [row] = Workloads.list(c.term.id)
    protected = List.last(row.sessions)

    historical =
      Repo.insert!(%NeuZeit.Planning.ScheduleException{
        term_id: c.term.id,
        session_id: protected.id,
        kind: "cancel",
        occurrence_date: c.term.starts_on,
        reason: "Cancellation history",
        created_by: "Administrator",
        status: "reverted"
      })

    [row] = Workloads.list(c.term.id)
    assert {:ok, :saved} = Catalog.save_workload(c.term.id, row, %{contact_hours: "30"})
    [updated] = Workloads.list(c.term.id)
    assert [%{id: retained_id}] = updated.sessions
    assert retained_id == protected.id
    assert Repo.get!(NeuZeit.Planning.ScheduleException, historical.id).session_id == protected.id
  end

  test "repeated full series for one cohort are not proposed as shared classes", c do
    assert {:ok, :saved} =
             Catalog.save_workload(c.term.id, nil, %{c.attrs | contact_hours: "60"})

    assert Catalog.merge_candidates(c.term.id) == []

    other_cohort = cohort_fixture()

    assert {:ok, :saved} =
             Catalog.save_workload(c.term.id, nil, %{
               c.attrs
               | contact_hours: "30",
                 cohort_ids: [other_cohort.id]
             })

    assert [candidate] = Catalog.merge_candidates(c.term.id)
    assert Enum.sort(candidate.cohorts) == Enum.sort([c.cohort.name, other_cohort.name])
  end

  @tag timeout: 30_000
  test "switching remainder parity resolves a shared-slot conflict", c do
    term = term_fixture()
    assert term.weeks_count == 16
    profile = slot_profile_fixture(term: term, cells: [%{day: 1, slot: 1}])

    for _ <- 1..2 do
      assert {:ok, :saved} =
               Catalog.save_workload(
                 term.id,
                 nil,
                 %{
                   c.attrs
                   | course_component_id: component_fixture(rooms: c.component.allowed_rooms).id,
                     contact_hours: "16",
                     week_mask: Enum.to_list(1..16)
                 }
                 |> Map.put(:slot_profile_id, profile.id)
               )
    end

    plan = plan_fixture(term: term)
    spec = plan.id |> SpecBuilder.build!() |> put_in([:solver, :time_limit], 5)
    assert {:error, %{"status" => "INFEASIBLE"}} = NeuZeit.Solver.solve(spec, timeout: 15_000)
    [_, second] = Workloads.list(term.id)
    assert {:ok, :saved} = Catalog.save_workload(term.id, second, %{remainder_parity: "even"})
    assert {:ok, result} = Planning.solve_plan(plan.id)
    assert result["status"] in ["OPTIMAL", "FEASIBLE"]
    assert Planning.check_plan(plan.id) == []
  end

  test "compatible hour edits preserve the weekly series and its placement", c do
    assert {:ok, :saved} = Catalog.save_workload(c.term.id, nil, c.attrs)
    [row] = Workloads.list(c.term.id)
    weekly = Enum.find(row.sessions, &(length(&1.week_mask) == 15))
    plan = plan_fixture(term: c.term)

    placed =
      placement_fixture(
        plan_id: plan.id,
        session_id: weekly.id,
        room_id: hd(c.component.allowed_rooms).id,
        day: 1,
        slot: 1,
        week_mask: weekly.week_mask,
        locked: true
      )

    [row] = Workloads.list(c.term.id)
    assert {:ok, :saved} = Catalog.save_workload(c.term.id, row, %{contact_hours: "47"})
    [updated] = Workloads.list(c.term.id)
    assert Enum.any?(updated.sessions, &(&1.id == weekly.id && &1.week_mask == weekly.week_mask))
    assert [%{id: placement_id, locked: true}] = Planning.list_placements(plan.id)
    assert placement_id == placed.id
    assert Workloads.meeting_count(updated) == 24
  end

  test "shrinking a placed remainder preserves its identity and synchronizes its placement", c do
    assert {:ok, :saved} = Catalog.save_workload(c.term.id, nil, c.attrs)
    [row] = Workloads.list(c.term.id)
    remainder = Enum.find(row.sessions, &(length(&1.week_mask) == 8))
    plan = plan_fixture(term: c.term)

    placement =
      placement_fixture(
        plan_id: plan.id,
        session_id: remainder.id,
        room_id: hd(c.component.allowed_rooms).id,
        day: 1,
        slot: 1,
        week_mask: remainder.week_mask
      )

    [row] = Workloads.list(c.term.id)
    assert {:ok, :saved} = Catalog.save_workload(c.term.id, row, %{rounding_mode: "down"})
    [retained] = Workloads.list(c.term.id)
    assert Decimal.equal?(retained.requirement.contact_hours, 45)
    assert Decimal.equal?(Workloads.planned_hours(retained, c.term), 44)
    assert Enum.map(retained.sessions, & &1.id) == Enum.map(row.sessions, & &1.id)
    assert Catalog.get_session!(remainder.id).week_mask == Enum.to_list(2..14//2)
    assert [updated_placement] = Planning.list_placements(plan.id)
    assert updated_placement.id == placement.id
    assert updated_placement.session_id == remainder.id
    assert updated_placement.week_mask == Enum.to_list(2..14//2)
    assert Planning.check_plan(plan.id) == []
  end

  test "preview and save preserve a custom remainder when an additional full series is needed",
       c do
    assert {:ok, :saved} = Catalog.save_workload(c.term.id, nil, c.attrs)
    [row] = Workloads.list(c.term.id)
    remainder = Enum.find(row.sessions, &(length(&1.week_mask) == 8))
    custom_mask = [1, 2, 4, 6, 8, 10, 12, 14]
    assert {:ok, _} = Sessions.update_generated_session(remainder, %{week_mask: custom_mask})
    [custom] = Workloads.list(c.term.id)
    changeset = Workload.changeset(custom.requirement, c.term, %{contact_hours: "75"})
    preview = Workload.preview(changeset, c.term, custom)
    assert preview.meeting_count == 38

    assert Enum.sort(preview.masks) ==
             Enum.sort([c.attrs.week_mask, c.attrs.week_mask, custom_mask])

    assert {:ok, :saved} = Catalog.save_workload(c.term.id, custom, %{contact_hours: "75"})
    [saved] = Workloads.list(c.term.id)
    assert masks(saved) == Enum.sort(preview.masks)
    assert Catalog.get_session!(remainder.id).week_mask == custom_mask

    assert Enum.all?(custom.sessions, fn series ->
             Enum.any?(saved.sessions, &(&1.id == series.id))
           end)

    assert Decimal.equal?(Workloads.planned_hours(saved, c.term), preview.planned_hours)
    assert :ok = Workloads.check(c.term.id)
  end

  test "a remainder with reverted exception history is protected from removal", c do
    assert {:ok, :saved} = Catalog.save_workload(c.term.id, nil, c.attrs)
    [row] = Workloads.list(c.term.id)
    remainder = Enum.find(row.sessions, &(length(&1.week_mask) == 8))

    historical =
      Repo.insert!(%NeuZeit.Planning.ScheduleException{
        term_id: c.term.id,
        session_id: remainder.id,
        kind: "cancel",
        occurrence_date: c.term.starts_on,
        reason: "Original cancellation",
        created_by: "Administrator",
        status: "reverted"
      })

    [row] = Workloads.list(c.term.id)
    assert {:error, _} = Catalog.save_workload(c.term.id, row, %{contact_hours: "30"})
    assert Repo.get!(NeuZeit.Planning.ScheduleException, historical.id).session_id == remainder.id
    assert Workloads.meeting_count(hd(Workloads.list(c.term.id))) == 23
  end

  test "legacy automatic placements keep different selected weeks in different plans", c do
    session =
      session_fixture(
        term: c.term,
        component: c.component,
        teacher: c.teacher,
        cohorts: [c.cohort],
        automatic_weeks: true,
        week_mask: [1, 2]
      )

    plans = for _ <- 1..2, do: plan_fixture(term: c.term)

    for {plan, week} <- Enum.with_index(plans, 1) do
      placement_fixture(
        plan_id: plan.id,
        session_id: session.id,
        room_id: hd(c.component.allowed_rooms).id,
        day: 1,
        slot: 1,
        week_mask: [week]
      )
    end

    assert {:ok, :ready} = Workloads.prepare(c.term.id)
    [row] = Workloads.list(c.term.id)
    assert {:ok, :saved} = Catalog.save_workload(c.term.id, row, %{automatic_weeks: false})
    assert Catalog.get_session!(session.id).automatic_weeks

    for {plan, week} <- Enum.with_index(plans, 1) do
      assert [%{session_id: id, week_mask: [^week]}] = Planning.list_placements(plan.id)
      assert id == session.id
    end
  end

  for hours <- [[45], [45, 30, 16, 8, 4]] do
    @tag timeout: 30_000
    test "solves #{length(hours)} workload(s) as recurring series over 15 weeks", c do
      rooms = for _ <- 1..3, do: room_fixture()

      for hours <- unquote(hours) do
        component = component_fixture(rooms: rooms)

        assert {:ok, :saved} =
                 Catalog.save_workload(c.term.id, nil, %{
                   c.attrs
                   | course_component_id: component.id,
                     teacher_id: teacher_fixture().id,
                     contact_hours: Integer.to_string(hours)
                 })
      end

      rows = Workloads.list(c.term.id)
      assert length(rows) == length(unquote(hours))
      plan = plan_fixture(term: c.term)
      assert {:ok, :ready} = Workloads.prepare(c.term.id)
      spec = SpecBuilder.build!(plan.id)
      refute Enum.any?(spec.sessions, &Map.get(&1, :choose_week, false))
      assert length(spec.sessions) == if(length(unquote(hours)) == 1, do: 2, else: 6)
      assert {:ok, result} = Planning.solve_plan(plan.id)
      assert result["status"] in ["OPTIMAL", "FEASIBLE"]
      assert Planning.check_plan(plan.id) == []
      assert length(Planning.list_placements(plan.id)) == length(spec.sessions)

      for row <- rows do
        placements =
          Enum.filter(Planning.list_placements(plan.id), &(&1.session.workload_id == row.id))

        assert Enum.sum(Enum.map(placements, &length(&1.week_mask))) ==
                 Workloads.meeting_count(row)
      end
    end
  end

  defp masks(row), do: row.sessions |> Enum.map(& &1.week_mask) |> Enum.sort()
end
