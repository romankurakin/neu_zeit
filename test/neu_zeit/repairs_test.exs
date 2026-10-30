defmodule NeuZeit.Planning.RepairsTest do
  use NeuZeit.DataCase, async: true

  import NeuZeit.Fixtures

  alias NeuZeit.Planning
  alias NeuZeit.Planning.Repairs

  setup do
    term = term_fixture()
    building = building_fixture()
    rooms = for _ <- 1..2, do: room_fixture(building: building)
    %{term: term, rooms: rooms, plan: plan_fixture(term: term)}
  end

  defp session(ctx, attrs) do
    attrs = Map.new(attrs)
    rooms = Map.get(attrs, :rooms, ctx.rooms)

    session_fixture(
      attrs
      |> Map.drop([:rooms])
      |> Map.merge(%{term: ctx.term, component: component_fixture(rooms: rooms)})
    )
  end

  defp profile(ctx, cells),
    do:
      slot_profile_fixture(
        term: ctx.term,
        cells: Enum.map(cells, fn {d, s} -> %{day: d, slot: s} end)
      )

  defp place(ctx, session, day, slot, attrs \\ %{}) do
    placement_fixture(
      Map.merge(
        %{
          plan_id: ctx.plan.id,
          session_id: session.id,
          room_id: hd(ctx.rooms).id,
          day: day,
          slot: slot
        },
        attrs
      )
    )
  end

  defp moves(repair), do: Enum.map(repair.moves, &{&1.session.id, &1.day, &1.slot})

  defp positions(plan) do
    plan.id
    |> Planning.list_placements()
    |> Map.new(&{&1.session_id, {&1.day, &1.slot, &1.room_id}})
  end

  describe "one move" do
    setup ctx do
      room = hd(ctx.rooms)
      selected = session(ctx, rooms: [room])
      blocker = session(ctx, rooms: [room])
      place(ctx, blocker, 1, 1)
      %{selected: selected, blocker: blocker, room: room}
    end

    test "moves the session that occupies the only room", ctx do
      result = Repairs.suggest(ctx.selected, ctx.plan.id, 1, 1)

      assert result.complete
      assert [best | _] = result.repairs
      assert best.room.id == ctx.room.id
      assert [{blocker_id, day, slot}] = moves(best)
      assert blocker_id == ctx.blocker.id
      assert {day, slot} != {1, 1}
      assert best.groups == Enum.map(ctx.blocker.cohorts, & &1.name)
      assert Enum.all?(result.repairs, &(length(&1.moves) == 1))

      assert {:ok, _ids} = Planning.change_placements(ctx.plan.id, best.changes)
      assert Planning.check_plan(ctx.plan.id) == []

      assert %{
               ctx.selected.id => {1, 1, ctx.room.id},
               ctx.blocker.id => {day, slot, ctx.room.id}
             } == positions(ctx.plan)
    end

    test "prefers the move that keeps the moved group's day compact", ctx do
      neighbour = session(ctx, rooms: [List.last(ctx.rooms)], cohorts: ctx.blocker.cohorts)
      place(ctx, neighbour, 3, 2, %{room_id: List.last(ctx.rooms).id})

      assert [best | _] = Repairs.suggest(ctx.selected, ctx.plan.id, 1, 1).repairs
      assert [{_id, 3, slot}] = moves(best)
      assert slot in [1, 3]
    end

    test "a start with a free room needs no repair", ctx do
      assert %{repairs: [], complete: true} = Repairs.suggest(ctx.selected, ctx.plan.id, 1, 2)
    end

    test "never moves a locked placement", ctx do
      {:ok, _} =
        Planning.update_placement(hd(Planning.list_placements(ctx.plan.id)), %{"locked" => true})

      assert %{repairs: [], complete: true} =
               Repairs.suggest(ctx.selected, ctx.plan.id, 1, 1)
    end

    test "reports a search stopped by its time limit", ctx do
      assert %{complete: false} = Repairs.suggest(ctx.selected, ctx.plan.id, 1, 1, timeout: 0)
    end
  end

  describe "two moves" do
    # The blocker can only use its own start and the next one, where a session of
    # the same teacher waits. That session can only move one slot later.
    setup ctx do
      teacher = teacher_fixture()
      selected = session(ctx, [])

      blocker =
        session(ctx,
          teacher: teacher,
          cohorts: selected.cohorts,
          slot_profile_id: profile(ctx, [{1, 1}, {1, 2}]).id
        )

      next = session(ctx, teacher: teacher, slot_profile_id: profile(ctx, [{1, 2}, {1, 3}]).id)
      place(ctx, blocker, 1, 1)
      place(ctx, next, 1, 2)
      %{selected: selected, blocker: blocker, next: next}
    end

    test "moves the blocker and the session it displaces", ctx do
      result = Repairs.suggest(ctx.selected, ctx.plan.id, 1, 1)

      assert result.complete
      assert [repair] = result.repairs
      assert moves(repair) == [{ctx.blocker.id, 1, 2}, {ctx.next.id, 1, 3}]

      assert {:ok, _ids} = Planning.change_placements(ctx.plan.id, repair.changes)
      assert Planning.check_plan(ctx.plan.id) == []
    end

    test "allows only one move when asked", ctx do
      assert %{repairs: [], complete: true} =
               Repairs.suggest(ctx.selected, ctx.plan.id, 1, 1, max_moves: 1)
    end

    test "stops at a locked placement in the chain", ctx do
      placement =
        Enum.find(Planning.list_placements(ctx.plan.id), &(&1.session_id == ctx.next.id))

      {:ok, _} = Planning.update_placement(placement, %{"locked" => true})

      assert %{repairs: [], complete: true} = Repairs.suggest(ctx.selected, ctx.plan.id, 1, 1)
    end
  end

  # The teacher teaches exactly the group's two sessions, so the solver weighs
  # their days once for the teacher and once for the group.
  test "weighs a teacher's and a group's identical weekly sessions twice", ctx do
    room = hd(ctx.rooms)
    teacher = teacher_fixture()
    cohorts = [cohort_fixture()]

    [first, second] =
      for _ <- 1..2, do: session(ctx, rooms: [room], teacher: teacher, cohorts: cohorts)

    blocker = session(ctx, rooms: [room])
    place(ctx, first, 1, 1)
    place(ctx, second, 3, 1)
    place(ctx, blocker, 1, 2)

    assert [best | _] = Repairs.suggest(second, ctx.plan.id, 1, 2).repairs
    # Two weeks for the teacher and two for the group, each with one active day
    # fewer: 4 * -2.
    assert best.penalty == -8
  end

  # Two generated meetings of one requirement, in weeks 1 and 2. A session of
  # the same teacher in week 2 blocks the second meeting's target, which is
  # where the first meeting is held.
  test "counts the times and rooms a requirement's meetings use", ctx do
    [room, other_room] = ctx.rooms
    teacher = teacher_fixture()
    component = component_fixture(rooms: ctx.rooms)
    cohorts = [cohort_fixture()]

    [first, second] =
      for _ <- 1..2 do
        session_fixture(
          term: ctx.term,
          component: component,
          teacher: teacher,
          cohorts: cohorts,
          automatic_weeks: true,
          week_mask: [1, 2]
        )
      end

    blocker =
      session(ctx,
        teacher: teacher,
        week_mask: [2],
        slot_profile_id: profile(ctx, [{2, 1}, {4, 1}]).id
      )

    place(ctx, first, 2, 1, %{week_mask: [1]})
    place(ctx, second, 3, 1, %{week_mask: [2]})
    place(ctx, blocker, 2, 1, %{room_id: other_room.id})

    assert [repair] = Repairs.suggest(%{second | week_mask: [2]}, ctx.plan.id, 2, 1).repairs
    assert repair.room.id == room.id
    assert moves(repair) == [{blocker.id, 4, 1}]
    # The teacher's week 2 keeps two active days, and both meetings now share
    # one time and room.
    assert repair.penalty == -1
  end

  # A lecture and a seminar of one sequence group, each a generated meeting of
  # weeks 1 and 2, held in different weeks. The solver relates them by the
  # weeks they may be held in.
  test "relates sequence blocks held in different weeks", ctx do
    room = hd(ctx.rooms)

    [lecture, seminar] =
      for _ <- 1..2 do
        session(ctx,
          rooms: [room],
          automatic_weeks: true,
          week_mask: [1, 2],
          sequence_group: "pair"
        )
      end

    blocker =
      session(ctx,
        rooms: [room],
        week_mask: [2],
        slot_profile_id: profile(ctx, [{1, 2}, {5, 1}]).id
      )

    place(ctx, lecture, 1, 1, %{week_mask: [1]})
    place(ctx, seminar, 1, 4, %{week_mask: [2]})
    place(ctx, blocker, 1, 2)

    assert [repair] = Repairs.suggest(%{seminar | week_mask: [2]}, ctx.plan.id, 1, 2).repairs
    assert moves(repair) == [{blocker.id, 5, 1}]
    # The seminar now follows the lecture: three slots apart before, so 8 * -3.
    assert repair.penalty == -24
  end

  test "two sessions can exchange rooms and starts", ctx do
    room = hd(ctx.rooms)
    profile = profile(ctx, [{1, 1}, {1, 2}])
    selected = session(ctx, rooms: [room], slot_profile_id: profile.id)
    blocker = session(ctx, rooms: [room], slot_profile_id: profile.id)
    place(ctx, selected, 1, 2)
    place(ctx, blocker, 1, 1)

    assert [repair] = Repairs.suggest(selected, ctx.plan.id, 1, 1).repairs
    assert moves(repair) == [{blocker.id, 1, 2}]
    assert {:ok, _ids} = Planning.change_placements(ctx.plan.id, repair.changes)

    assert %{selected.id => {1, 1, room.id}, blocker.id => {1, 2, room.id}} ==
             positions(ctx.plan)
  end

  test "a batch that leaves a conflict changes nothing", ctx do
    room = hd(ctx.rooms)
    first = session(ctx, rooms: [room])
    second = session(ctx, rooms: [room])
    place(ctx, first, 1, 1)

    assert {:error, %{errors: [%{type: "room_conflict"} | _]}} =
             Planning.change_placements(ctx.plan.id, [
               %{session_id: second.id, day: 1, slot: 1, room_id: room.id}
             ])

    assert map_size(positions(ctx.plan)) == 1
  end
end
