defmodule NeuZeit.Constraints.ProjectionTest do
  use ExUnit.Case, async: true

  alias NeuZeit.Catalog.Term
  alias NeuZeit.Constraints.Projection
  alias NeuZeit.Planning.{Placement, ScheduleException}

  test "projects occurrences in chronological order" do
    term = %Term{starts_on: ~D[2026-09-07], excluded_dates: []}

    placements = [
      %Placement{
        id: "later-placement",
        session_id: "later-session",
        room_id: "room",
        week_mask: [5],
        day: 5,
        slot: 1
      },
      %Placement{
        id: "earlier-placement",
        session_id: "earlier-session",
        room_id: "room",
        week_mask: [1],
        day: 1,
        slot: 1
      }
    ]

    assert Enum.map(Projection.project(term, placements), & &1.date) == [
             ~D[2026-09-07],
             ~D[2026-10-09]
           ]
  end

  test "applies active move and cancellation exceptions" do
    term = %Term{starts_on: ~D[2026-09-07], excluded_dates: []}

    placements = [
      %Placement{
        id: "moved-placement",
        session_id: "moved-session",
        room_id: "original-room",
        week_mask: [1],
        day: 1,
        slot: 1
      },
      %Placement{
        id: "cancelled-placement",
        session_id: "cancelled-session",
        room_id: "room",
        week_mask: [1],
        day: 1,
        slot: 1
      }
    ]

    exceptions = [
      %ScheduleException{
        id: "move",
        session_id: "moved-session",
        occurrence_date: ~D[2026-09-07],
        kind: "move",
        status: "active",
        new_date: ~D[2026-09-09],
        new_slot: 3,
        new_room_id: "new-room"
      },
      %ScheduleException{
        id: "cancel",
        session_id: "cancelled-session",
        occurrence_date: ~D[2026-09-07],
        kind: "cancel",
        status: "active"
      }
    ]

    assert [
             %{
               session_id: "moved-session",
               date: ~D[2026-09-09],
               day: 3,
               slot: 3,
               room_id: "new-room",
               exception_id: "move",
               source: :move
             }
           ] = Projection.project(term, placements, exceptions)
  end

  test "moves relocate occurrences away from excluded dates" do
    term = %Term{starts_on: ~D[2026-09-07], excluded_dates: [~D[2026-09-07]]}

    placement = %Placement{
      id: "holiday-placement",
      session_id: "holiday-session",
      room_id: "room",
      week_mask: [1],
      day: 1,
      slot: 1
    }

    move = %ScheduleException{
      id: "makeup",
      session_id: "holiday-session",
      occurrence_date: ~D[2026-09-07],
      kind: "move",
      status: "active",
      new_date: ~D[2026-09-09],
      new_slot: 2,
      new_room_id: "room"
    }

    assert [
             %{
               session_id: "holiday-session",
               date: ~D[2026-09-09],
               slot: 2,
               exception_id: "makeup",
               source: :move
             }
           ] = Projection.project(term, [placement], [move])

    assert Projection.project(term, [placement], []) == []
  end

  test "omits excluded template dates and keeps active additions" do
    term = %Term{starts_on: ~D[2026-09-07], excluded_dates: [~D[2026-09-14]]}

    placement = %Placement{
      id: "template-placement",
      session_id: "template-session",
      room_id: "template-room",
      week_mask: [1, 2],
      day: 1,
      slot: 1
    }

    addition = %ScheduleException{
      id: "addition",
      session_id: "added-session",
      occurrence_date: ~D[2026-09-14],
      kind: "add",
      status: "active",
      new_slot: 2,
      new_room_id: "added-room"
    }

    assert [
             %{session_id: "template-session", date: ~D[2026-09-07], source: :template},
             %{
               session_id: "added-session",
               date: ~D[2026-09-14],
               day: 1,
               slot: 2,
               room_id: "added-room",
               exception_id: "addition",
               source: :add
             }
           ] = Projection.project(term, [placement], [addition])
  end

  test "does not project template occurrences past a partial final week" do
    term = %Term{
      starts_on: ~D[2026-09-07],
      ends_on: ~D[2026-09-16],
      excluded_dates: []
    }

    placement = %Placement{
      id: "tail-placement",
      session_id: "tail-session",
      room_id: "room",
      week_mask: [2],
      day: 5,
      slot: 1
    }

    assert Projection.project(term, [placement]) == []
  end
end
