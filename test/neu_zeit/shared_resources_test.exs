defmodule NeuZeit.SharedResourcesTest do
  use NeuZeit.DataCase, async: true
  import NeuZeit.Fixtures
  alias NeuZeit.{Catalog, Planning}
  alias NeuZeit.Planning.Feasibility
  alias NeuZeit.Solver.{SpecBuilder, ResultValidator, OrToolsPort}

  defp place(plan, session, room, day \\ 1, slot \\ 1) do
    Planning.create_placement(%{
      plan_id: plan.id,
      session_id: session.id,
      room_id: room.id,
      day: day,
      slot: slot
    })
  end

  defp pair do
    a = term_fixture(%{name: "Term A"})
    b = term_fixture(%{name: "Term B", starts_on: ~D[2026-09-07]})
    room = room_fixture()
    component = component_fixture(rooms: [room])
    sa = session_fixture(term: a, component: component, week_mask: [2], duration_slots: 2)
    sb = session_fixture(term: b, component: component, week_mask: [1])
    pa = plan_fixture(term: a)
    pb = plan_fixture(term: b)
    %{a: a, b: b, room: room, sa: sa, sb: sb, pa: pa, pb: pb}
  end

  test "different week numbers still conflict on the same date and continuation slot" do
    c = pair()
    assert {:ok, _} = place(c.pa, c.sa, c.room)
    assert {:ok, _} = Planning.publish_plan(c.pa.id)
    assert {:error, %{errors: errors}} = place(c.pb, c.sb, c.room, 1, 2)
    assert Enum.any?(errors, &(&1.type == "external_room_conflict" and &1.date == ~D[2026-09-07]))
    assert hd(errors).message =~ "Term A"
    assert hd(errors).message =~ "Term B"
    refute Map.has_key?(Feasibility.cells_for(c.sb, c.pb.id), {1, 2})
    assert {:ok, _} = place(c.pb, c.sb, c.room, 1, 3)
  end

  test "drafts do not reserve resources but later publication rechecks the full calendar" do
    c = pair()
    assert {:ok, _} = place(c.pa, c.sa, c.room)
    assert {:ok, _} = place(c.pb, c.sb, c.room, 1, 2)
    assert {:ok, _} = Planning.publish_plan(c.pa.id)
    assert {:error, %{errors: errors}} = Planning.publish_plan(c.pb.id)
    assert Enum.any?(errors, &(&1.type == "external_room_conflict"))
    assert Planning.get_plan!(c.pb.id).status == "draft"
    assert Planning.get_plan!(c.pa.id).status == "active"
  end

  test "holidays release resources and restoring a holiday revalidates published bookings" do
    c = pair()
    {:ok, a} = Catalog.update_term(c.a, %{excluded_dates: [~D[2026-09-07]]})
    {:ok, _} = place(c.pa, c.sa, c.room)
    {:ok, _} = Planning.publish_plan(c.pa.id)
    assert {:ok, _} = place(c.pb, c.sb, c.room)
    {:ok, _} = Planning.publish_plan(c.pb.id)
    assert {:error, %{errors: errors}} = Catalog.update_term(a, %{excluded_dates: []})
    assert Enum.any?(errors, &(&1.type == "external_room_conflict"))
    assert Catalog.get_term!(a.id).excluded_dates == [~D[2026-09-07]]
  end

  test "cancellation releases a booking and reverting it cannot collide with another term" do
    c = pair()
    {:ok, _} = place(c.pa, c.sa, c.room)
    {:ok, _} = Planning.publish_plan(c.pa.id)

    {:ok, cancel} =
      Planning.create_schedule_exception(%{
        session_id: c.sa.id,
        kind: "cancel",
        occurrence_date: ~D[2026-09-07],
        reason: "No class",
        created_by: "Administrator"
      })

    assert {:ok, _} = place(c.pb, c.sb, c.room)
    {:ok, _} = Planning.publish_plan(c.pb.id)

    assert {:error, %{errors: errors}} =
             Planning.update_schedule_exception(cancel, %{status: "reverted"})

    assert Enum.any?(errors, &(&1.type == "external_room_conflict"))
    assert Planning.get_schedule_exception!(cancel.id).status == "active"
  end

  test "move and add targets check external bookings including duration" do
    c = pair()
    {:ok, _} = place(c.pa, c.sa, c.room)
    {:ok, _} = place(c.pb, c.sb, c.room, 2)
    {:ok, _} = Planning.publish_plan(c.pa.id)
    {:ok, _} = Planning.publish_plan(c.pb.id)

    for kind <- ["move", "add"] do
      attrs = %{
        session_id: c.sb.id,
        kind: kind,
        occurrence_date: if(kind == "move", do: ~D[2026-09-08], else: ~D[2026-09-07]),
        new_date: ~D[2026-09-07],
        new_slot: 2,
        new_room_id: c.room.id,
        reason: "Make-up",
        created_by: "Administrator"
      }

      assert {:error, %{errors: errors}} = Planning.create_schedule_exception(attrs)
      assert Enum.any?(errors, &(&1.type == "external_room_conflict"))
    end
  end

  test "teachers and cohorts conflict across terms even in different rooms" do
    c = pair()
    other_room = room_fixture()
    other_component = component_fixture(rooms: [other_room])
    {:ok, _} = place(c.pa, c.sa, c.room)
    {:ok, _} = Planning.publish_plan(c.pa.id)

    for {attrs, type} <- [
          {[teacher: c.sa.teacher], "external_teacher_conflict"},
          {[cohorts: c.sa.cohorts], "external_cohort_conflict"}
        ] do
      session = session_fixture([term: c.b, component: other_component, week_mask: [1]] ++ attrs)
      assert {:error, %{errors: errors}} = place(c.pb, session, other_room)
      assert Enum.any?(errors, &(&1.type == type))
    end
  end

  test "solver avoids external bookings and stale output is independently rejected" do
    c = pair()
    {:ok, _} = place(c.pa, c.sa, c.room)
    {:ok, _} = Planning.publish_plan(c.pa.id)
    spec = SpecBuilder.build!(c.pb.id)
    assert %{day: 1, slot: 2, room: c.room.id} in hd(spec.sessions).blocked_assignments
    bad = %{"assignment" => %{c.sb.id => %{"day" => 1, "slot" => 2, "room" => c.room.id}}}
    assert {:error, %{errors: errors}} = ResultValidator.validate(c.pb.id, spec, bad)
    assert Enum.any?(errors, &(&1.type == "external_room_conflict"))
    assert {:ok, result} = OrToolsPort.solve(put_in(spec.solver.time_limit, 2))
    assert {:ok, _} = ResultValidator.validate(c.pb.id, spec, result)
  end

  test "exception audit data is required and explicit term mismatch is rejected" do
    c = pair()

    attrs = %{
      session_id: c.sa.id,
      kind: "add",
      occurrence_date: ~D[2026-09-07],
      new_slot: 4,
      new_room_id: c.room.id,
      reason: "Make-up"
    }

    assert {:error, changeset} = Planning.create_schedule_exception(attrs)
    assert errors_on(changeset).created_by == ["can't be blank"]

    assert {:error, changeset} =
             Planning.create_schedule_exception(
               Map.merge(attrs, %{created_by: "Admin", term_id: c.b.id})
             )

    assert errors_on(changeset).term_id == ["must match the session term"]
  end
end
