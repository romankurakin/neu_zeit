defmodule NeuZeit.WorkloadProposalTest do
  use NeuZeit.DataCase, async: true
  import NeuZeit.Fixtures

  alias NeuZeit.{Catalog, Planning, Repo}
  alias NeuZeit.Catalog.{Sessions, Workload, WorkloadDistribution, Workloads, WorkloadSnapshot}
  alias NeuZeit.Planning.ScheduleException

  setup do
    term = term_fixture(starts_on: ~D[2026-08-31], ends_on: ~D[2026-12-12])
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

  test "a reloaded requirement uses the supplied term's academic-hour unit", c do
    term = term_fixture(academic_hour_minutes: 30)
    assert {:ok, :saved} = Catalog.save_workload(term.id, nil, %{c.attrs | contact_hours: "6"})
    [snapshot] = Workloads.list(term.id)
    requirement = Repo.get!(Workload, snapshot.id)

    proposal = Workload.preview(requirement, term, snapshot)

    assert proposal.meeting_count == 2
    assert proposal.meeting_count == Workloads.meeting_count(snapshot)
    assert Decimal.equal?(proposal.required_hours, 6)
    assert Decimal.equal?(proposal.planned_hours, Workloads.planned_hours(snapshot, term))
    assert Decimal.equal?(proposal.planned_hours, 6)
    assert Enum.sort(proposal.masks) == masks(snapshot)
  end

  test "a capacity error on rounding up still exposes the valid lower choice", c do
    term =
      term_fixture(
        grid: %{
          days: ["Mon"],
          slots: [%{start: "08:00", end: "09:30"}, %{start: "09:30", end: "11:00"}]
        }
      )

    attrs = %{c.attrs | contact_hours: "5", week_mask: [1]}
    changeset = Workload.changeset(Workload.new(term), term, attrs)
    refute changeset.valid?
    assert Keyword.has_key?(changeset.errors, :contact_hours)

    proposal = Workload.preview(changeset, term)
    assert proposal.meeting_count == 3
    assert proposal.lower_count == 2
    assert proposal.upper_count == 3
    assert proposal.lower_fits?
    refute proposal.upper_fits?
    refute proposal.within_capacity?

    assert {:error, %Ecto.Changeset{}} = Catalog.save_workload(term.id, nil, attrs)

    assert {:ok, :saved} =
             Catalog.save_workload(term.id, nil, Map.put(attrs, :rounding_mode, "down"))

    [snapshot] = Workloads.list(term.id)
    assert Workloads.meeting_count(snapshot) == 2
    assert Decimal.equal?(snapshot.requirement.contact_hours, 5)
    assert Decimal.equal?(Workloads.planned_hours(snapshot, term), 4)
  end

  test "preview and save retain the same protected custom remainder", c do
    assert {:ok, :saved} =
             Catalog.save_workload(c.term.id, nil, %{c.attrs | contact_hours: "28"})

    [snapshot] = Workloads.list(c.term.id)
    [original] = snapshot.sessions

    assert {:ok, _} =
             Sessions.update_generated_session(original, %{week_mask: Enum.to_list(1..7)})

    assert {:ok, _} =
             Sessions.create_generated_session(
               snapshot.id,
               Map.merge(c.attrs, %{
                 term_id: c.term.id,
                 automatic_weeks: false,
                 week_mask: Enum.to_list(8..14)
               })
             )

    [split] = Workloads.list(c.term.id)
    [first, last] = Enum.sort_by(split.sessions, & &1.id)

    assert {:ok, _} =
             Sessions.update_generated_session(first, %{week_mask: Enum.to_list(1..7)})

    assert {:ok, _} =
             Sessions.update_generated_session(last, %{week_mask: Enum.to_list(8..14)})

    plan = plan_fixture(term: c.term)

    placement =
      placement_fixture(
        plan_id: plan.id,
        session_id: last.id,
        room_id: hd(c.component.allowed_rooms).id,
        day: 1,
        slot: 1,
        week_mask: Enum.to_list(8..14)
      )

    [snapshot] = Workloads.list(c.term.id)
    assert :ok = Workloads.check(c.term.id)
    assert MapSet.member?(snapshot.placed_ids, last.id)

    proposal =
      snapshot.requirement
      |> Workload.changeset(c.term, %{contact_hours: "44"})
      |> Workload.preview(c.term, snapshot)

    expected = Enum.sort([{first.id, Enum.to_list(1..15)}, {last.id, Enum.to_list(8..14)}])

    assert Enum.sort(Enum.map(proposal.retained, fn {series, mask} -> {series.id, mask} end)) ==
             expected

    assert proposal.new_masks == []
    assert proposal.removed == []

    assert {:ok, :saved} =
             Catalog.save_workload(c.term.id, snapshot, %{contact_hours: "44"})

    [saved] = Workloads.list(c.term.id)
    assert Enum.sort(Enum.map(saved.sessions, &{&1.id, &1.week_mask})) == expected
    assert masks(saved) == Enum.sort(proposal.masks)
    assert Decimal.equal?(Workloads.planned_hours(saved, c.term), proposal.planned_hours)

    assert [%{id: placement_id, session_id: session_id, week_mask: weeks}] =
             Planning.list_placements(plan.id)

    assert placement_id == placement.id
    assert session_id == last.id
    assert weeks == Enum.to_list(8..14)
    assert Planning.check_plan(plan.id) == []
  end

  test "a newly placed series invalidates the editor's earlier snapshot", c do
    assert {:ok, :saved} = Catalog.save_workload(c.term.id, nil, c.attrs)
    [opened] = Workloads.list(c.term.id)
    weekly = Enum.find(opened.sessions, &(length(&1.week_mask) == 15))
    plan = plan_fixture(term: c.term)

    placed =
      placement_fixture(
        plan_id: plan.id,
        session_id: weekly.id,
        room_id: hd(c.component.allowed_rooms).id,
        day: 1,
        slot: 1,
        week_mask: weekly.week_mask
      )

    assert {:error, {:conflict, "The workload changed. Reload it before saving."}} =
             Catalog.save_workload(c.term.id, opened, %{contact_hours: "47"})

    [refreshed] = Workloads.list(c.term.id)
    assert Decimal.equal?(refreshed.requirement.contact_hours, 45)
    assert MapSet.member?(refreshed.placed_ids, weekly.id)

    assert {:ok, :saved} =
             Catalog.save_workload(c.term.id, refreshed, %{contact_hours: "47"})

    assert [%{id: placement_id}] = Planning.list_placements(plan.id)
    assert placement_id == placed.id
  end

  test "new exception history invalidates an earlier snapshot even when reverted", c do
    assert {:ok, :saved} = Catalog.save_workload(c.term.id, nil, c.attrs)
    [opened] = Workloads.list(c.term.id)
    weekly = Enum.find(opened.sessions, &(length(&1.week_mask) == 15))

    exception =
      Repo.insert!(%ScheduleException{
        term_id: c.term.id,
        session_id: weekly.id,
        kind: "cancel",
        occurrence_date: c.term.starts_on,
        reason: "Preserved cancellation history",
        created_by: "Administrator",
        status: "reverted"
      })

    assert {:error, {:conflict, "The workload changed. Reload it before saving."}} =
             Catalog.save_workload(c.term.id, opened, %{contact_hours: "47"})

    [refreshed] = Workloads.list(c.term.id)
    assert Decimal.equal?(refreshed.requirement.contact_hours, 45)
    assert MapSet.member?(refreshed.history_ids, weekly.id)

    assert {:ok, :saved} =
             Catalog.save_workload(c.term.id, refreshed, %{contact_hours: "47"})

    assert Repo.get!(ScheduleException, exception.id).session_id == weekly.id
  end

  test "placing another workload does not invalidate this requirement's snapshot", c do
    assert {:ok, :saved} = Catalog.save_workload(c.term.id, nil, c.attrs)
    [opened] = Workloads.list(c.term.id)
    other_component = component_fixture()

    assert {:ok, :saved} =
             Catalog.save_workload(c.term.id, nil, %{
               c.attrs
               | course_component_id: other_component.id,
                 contact_hours: "30"
             })

    other = Enum.find(Workloads.list(c.term.id), &(&1.id != opened.id))
    [other_series] = other.sessions
    plan = plan_fixture(term: c.term)

    placement_fixture(
      plan_id: plan.id,
      session_id: other_series.id,
      room_id: hd(other_component.allowed_rooms).id,
      day: 1,
      slot: 1,
      week_mask: other_series.week_mask
    )

    refreshed = Enum.find(Workloads.list(c.term.id), &(&1.id == opened.id))
    refute MapSet.member?(refreshed.placed_ids, other_series.id)

    assert {:ok, :saved} =
             Catalog.save_workload(c.term.id, opened, %{contact_hours: "47"})
  end

  test "the read model keeps requirement metadata separate from generated series", c do
    assert {:ok, :saved} = Catalog.save_workload(c.term.id, nil, c.attrs)
    assert [%WorkloadSnapshot{} = snapshot] = Workloads.list(c.term.id)
    assert %Workload{} = snapshot.requirement
    assert snapshot.id == snapshot.requirement.id
    assert snapshot.requirement.course_component.id == c.component.id
    assert snapshot.requirement.teacher.id == c.teacher.id
    assert Enum.map(snapshot.requirement.cohorts, & &1.id) == [c.cohort.id]
    assert snapshot.requirement.slot_profile == nil
    assert Enum.all?(snapshot.sessions, &(&1.workload_id == snapshot.id && &1.id != snapshot.id))
    assert Workloads.series_count(snapshot) == 2
    assert Workloads.meeting_count(snapshot) == 23
    refute Map.has_key?(snapshot, :session)
    refute Map.has_key?(snapshot, :count)
  end

  test "distribution rejects missing or foreign editing context and hours reject another term",
       c do
    assert {:ok, :saved} = Catalog.save_workload(c.term.id, nil, c.attrs)
    [snapshot] = Workloads.list(c.term.id)
    other_term = term_fixture(academic_hour_minutes: 30)
    assert {:ok, :saved} = Catalog.save_workload(other_term.id, nil, c.attrs)
    [other] = Workloads.list(other_term.id)

    invalid_snapshots = [
      nil,
      other,
      %{snapshot | requirement: %{snapshot.requirement | term_id: other_term.id}},
      %{snapshot | sessions: other.sessions},
      %{snapshot | placed_ids: MapSet.new([hd(other.sessions).id])}
    ]

    for invalid <- invalid_snapshots do
      assert_raise ArgumentError, ~r/matching editing snapshot/, fn ->
        WorkloadDistribution.propose(snapshot.requirement, c.term, invalid)
      end
    end

    assert_raise ArgumentError, ~r/matching editing snapshot/, fn ->
      WorkloadDistribution.propose(snapshot.requirement, other_term, snapshot)
    end

    assert_raise ArgumentError, ~r/matching editing snapshot/, fn ->
      Workload.preview(snapshot.requirement, c.term)
    end

    assert_raise ArgumentError, "Planned hours require the workload's term", fn ->
      Workloads.planned_hours(snapshot, other_term)
    end

    proposal =
      Workload.new(c.term)
      |> Workload.changeset(c.term, c.attrs)
      |> Workload.preview(c.term)

    assert proposal.meeting_count == 23
  end

  defp masks(snapshot), do: snapshot.sessions |> Enum.map(& &1.week_mask) |> Enum.sort()
end
