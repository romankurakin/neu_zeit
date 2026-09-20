defmodule NeuZeit.WorkloadHourUnitsTest do
  use NeuZeit.DataCase, async: true
  import NeuZeit.Fixtures
  alias NeuZeit.{Catalog, Curriculum, Planning}

  test "one term hour unit is used for every load and cannot be overridden" do
    term = term_fixture(%{academic_hour_minutes: 30})
    component = component_fixture()
    cohort = cohort_fixture()

    for _ <- 1..2 do
      assert {:ok, :saved} =
               Catalog.save_workload(term.id, nil, %{
                 course_component_id: component.id,
                 teacher_id: teacher_fixture().id,
                 cohort_ids: [cohort.id],
                 week_mask: [1, 2],
                 duration_slots: 1,
                 contact_hours: "6",
                 academic_hour_minutes: 60
               })
    end

    rows = Catalog.list_workload(term.id)

    assert Enum.all?(
             rows,
             &(Catalog.Workloads.series_count(&1) == 1 && Catalog.Workloads.meeting_count(&1) == 2)
           )

    assert {:ok, :ready} = Catalog.Workloads.prepare(term.id)
    assert :ok = Catalog.Workloads.check(term.id)
    assert Enum.map(Catalog.list_workload(term.id), &Catalog.Workloads.series_count/1) == [1, 1]
    plan = plan_fixture(term: term)
    coverage = Curriculum.plan_coverage(plan.id)
    assert length(coverage) == 1
    assert Enum.all?(coverage, &(&1.required_hours == 6.0 and &1.planned_hours == 6.0))
    assert Curriculum.course_contact_coverage(term.id, component.course_id).required_hours == 6.0

    for {row, slot} <- Enum.with_index(rows, 1),
        session <- row.sessions do
      placement_fixture(
        plan_id: plan.id,
        session_id: session.id,
        room_id: hd(component.allowed_rooms).id,
        day: 1,
        slot: slot,
        week_mask: session.week_mask
      )
    end

    assert {:ok, _} = Planning.publish_plan(plan.id)
    assert Enum.all?(Curriculum.plan_coverage(plan.id), &(&1.calendar_hours == 6.0))
  end
end
