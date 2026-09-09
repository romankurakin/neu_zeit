defmodule NeuZeit.Solver.PureContractTest do
  use ExUnit.Case, async: true

  alias NeuZeit.Catalog.{CourseComponent, Room, Session, Teacher, TeacherAvailabilityCell, Term}
  alias NeuZeit.Planning.{Placement, Plan}
  alias NeuZeit.Solver.{ResultValidator, SpecBuilder}

  # No SQL sandbox: these checks must work with an in-memory snapshot only.
  setup do
    term = %Term{
      id: id(1),
      name: "Autumn",
      starts_on: ~D[2026-09-07],
      ends_on: ~D[2026-09-20],
      weeks_count: 2,
      excluded_dates: []
    }

    room = %Room{id: id(2), name: "101", building_id: id(3)}

    teacher = %Teacher{
      id: id(4),
      name: "A. Weber",
      availability_cells:
        for(slot <- [2, 3], do: %TeacherAvailabilityCell{term_id: term.id, day: 1, slot: slot})
    }

    session = %Session{
      id: id(5),
      term_id: term.id,
      teacher_id: teacher.id,
      teacher: teacher,
      cohorts: [],
      slot_profile: nil,
      duration_slots: 2,
      week_mask: [1, 2],
      course_component: %CourseComponent{allowed_rooms: [room]}
    }

    snapshot = %{
      plan: %Plan{id: id(6), term_id: term.id, term: term},
      rooms: [room],
      sessions: [session],
      placements: [],
      external: %{},
      config: NeuZeit.Config.load!()
    }

    result = %{
      "status" => "OPTIMAL",
      "objective" => 123,
      "unplaced" => [],
      "assignment" => %{session.id => %{"room" => room.id, "day" => 1, "slot" => 2}}
    }

    %{snapshot: snapshot, result: result, session: session, room: room}
  end

  test "builds only starts that fit the teacher's entire block", %{snapshot: snapshot} do
    assert [%{allowed_starts: [%{day: 1, slot: 2}]}] = SpecBuilder.build(snapshot).sessions
  end

  test "validation is deterministic and strips the unverified objective", %{
    snapshot: snapshot,
    result: result
  } do
    spec = SpecBuilder.build(snapshot)
    assert {:ok, validated} = ResultValidator.validate_snapshot(snapshot, spec, result)
    assert ResultValidator.validate_snapshot(snapshot, spec, result) == {:ok, validated}
    refute Map.has_key?(validated.result, "objective")
    assert [%{duration_slots: 2, week_mask: [1, 2]}] = validated.placements
  end

  test "rejects a room outside the snapshot and a moved lock", %{
    snapshot: snapshot,
    result: result,
    session: session,
    room: room
  } do
    spec = SpecBuilder.build(snapshot)
    unknown_room = put_in(result, ["assignment", session.id, "room"], id(99))

    assert {:error, %{errors: [%{type: "unknown_room"}]}} =
             ResultValidator.validate_snapshot(snapshot, spec, unknown_room)

    snapshot = %{
      snapshot
      | placements: [
          %Placement{session_id: session.id, room_id: room.id, day: 1, slot: 3, locked: true}
        ]
    }

    assert {:error, %{errors: [%{type: "locked_placement_moved"}]}} =
             ResultValidator.validate_snapshot(snapshot, SpecBuilder.build(snapshot), result)
  end

  test "uses the supplied grid when checking output", %{snapshot: snapshot, result: result} do
    snapshot =
      put_in(snapshot, [:config, :grid, :slots], Enum.take(snapshot.config.grid.slots, 2))

    assert {:error, %{errors: errors}} =
             ResultValidator.validate_snapshot(snapshot, SpecBuilder.build(snapshot), result)

    assert Enum.any?(errors, &(&1.type == "grid_bounds"))
  end

  test "build and validation use the same dated external booking", %{
    snapshot: snapshot,
    result: result,
    room: room
  } do
    booking = %{
      term_name: "Other term",
      term_id: id(10),
      plan_id: id(11),
      session_id: id(12),
      course: "Algorithms",
      teacher: "B. Braun",
      room: "101",
      cohorts: "",
      slot: 3
    }

    snapshot = %{snapshot | external: %{{~D[2026-09-07], 3, "room", room.id} => [booking]}}
    spec = SpecBuilder.build(snapshot)
    assert [%{blocked_assignments: [%{day: 1, slot: 2, room: room_id}]}] = spec.sessions
    assert room_id == room.id

    assert {:error, %{errors: [%{type: "external_room_conflict", date: ~D[2026-09-07]}]}} =
             ResultValidator.validate_snapshot(snapshot, spec, result)
  end

  defp id(n), do: "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")
end
