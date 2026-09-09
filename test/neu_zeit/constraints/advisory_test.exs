defmodule NeuZeit.Constraints.AdvisoryTest do
  use NeuZeit.DataCase, async: true

  import NeuZeit.Fixtures

  alias NeuZeit.Planning

  test "reports base cohort and legacy subgroup overlaps without blocking the plan" do
    term = term_fixture()
    room_a = room_fixture(name: "Base room")
    room_b = room_fixture(name: "Language room")
    base = cohort_fixture(name: "1A-MO")
    subgroup = cohort_fixture(name: "D12")

    base_session =
      session_fixture(
        term: term,
        component: component_fixture(rooms: [room_a]),
        teacher: teacher_fixture(name: "Base teacher"),
        cohorts: [base],
        week_mask: [1, 2],
        duration_slots: 2
      )

    subgroup_session =
      session_fixture(
        term: term,
        component: component_fixture(rooms: [room_b]),
        teacher: teacher_fixture(name: "Language teacher"),
        cohorts: [subgroup],
        week_mask: [2]
      )

    plan = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: plan.id,
      session_id: base_session.id,
      room_id: room_a.id,
      day: 1,
      slot: 1
    })

    placement_fixture(%{
      plan_id: plan.id,
      session_id: subgroup_session.id,
      room_id: room_b.id,
      day: 1,
      slot: 2
    })

    assert Planning.check_plan(plan.id) == []

    assert [advisory] = Planning.plan_advisories(plan.id)
    assert advisory.type == "unverified_cohort_overlap"
    assert advisory.day == 1
    assert advisory.slots == [2]
    assert advisory.weeks == [2]
    assert Enum.sort(advisory.cohorts) == [["1A-MO"], ["D12"]]
  end
end
