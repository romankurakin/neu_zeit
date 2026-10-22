defmodule NeuZeit.Planning.Repairs do
  @moduledoc """
  Suggests repairs for a start that other placements block.

  A repair places the selected session at the start and moves up to two other
  unlocked placements, so that the result passes the hard checks. Locked
  placements never move. The search follows the suggestions of UniTime (Müller,
  Murray and Rudová, PATAT 2010): depth-first, limited by moves and by time.

  Repairs are ranked by moves, then by the change in the soft penalty that the
  solver minimizes: gaps, active days, buildings per day, related blocks and
  meetings lost on non-teaching dates. Week sets never change.
  """

  alias NeuZeit.{Catalog, Config, Planning}
  alias NeuZeit.Constraints.{AutomaticWeeks, Soft}
  alias NeuZeit.Planning.{Placement, SharedResources}
  alias NeuZeit.Scheduling.TermDates

  @doc """
  Returns repairs for placing `session` at `{day, slot}`.

  The result is `%{repairs: repairs, complete: boolean}`.
  `complete` is false when `:timeout` (milliseconds, default 5000) ended the
  search before every option was checked. Options: `:max_moves` (default 2) and
  `:limit` (default 5). The caller passes the session with the week set it is
  edited for, as `Feasibility.cells_for/3` expects.

  Each repair has the session's `room`, the other `moves`, the affected
  `groups`, the soft `penalty` change (lower is better) and the `changes` for
  `NeuZeit.Planning.change_placements/2`.
  """
  def suggest(session, plan_id, day, slot, opts \\ []) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, 5_000)
    ctx = context(session, plan_id, deadline)
    max_moves = Keyword.get(opts, :max_moves, 2)

    # One move first, so a short limit still returns the smallest repairs.
    {solutions, complete} =
      Enum.reduce_while(1..max_moves//1, {%{}, true}, fn moves, {found, _complete} ->
        case explore(%{ctx | max_moves: moves}, day, slot, found) do
          {:done, found} -> {:cont, {found, true}}
          {:stopped, found} -> {:halt, {found, false}}
        end
      end)

    %{
      repairs:
        solutions
        |> Map.values()
        |> Enum.sort_by(&rank/1)
        |> Enum.take(Keyword.get(opts, :limit, 5))
        |> Enum.map(&present(ctx, &1)),
      complete: complete
    }
  end

  # Search

  defp explore(ctx, day, slot, found) do
    selected = ctx.items[ctx.selected]
    state = %{positions: ctx.positions, index: ctx.index, moved: [], queue: []}

    choices =
      if not selected.locked and {day, slot} in ctx.starts[selected.id],
        do: choices(ctx, state, selected, day, slot),
        else: []

    # A free room needs no repair. The inspector offers it directly.
    found =
      if Enum.any?(choices, fn {_room, displaced} -> displaced == [] end) do
        found
      else
        Enum.reduce(choices, found, fn {room, displaced}, found ->
          search(ctx, place(ctx, state, selected, {day, slot, room}, displaced), found)
        end)
      end

    {:done, found}
  catch
    {:deadline, found} -> {:stopped, found}
  end

  defp search(ctx, %{queue: []} = state, found), do: record(ctx, state, found)

  defp search(ctx, %{queue: [id | queue]} = state, found) do
    item = ctx.items[id]
    state = %{state | queue: queue}

    for {day, slot} <- ctx.starts[id],
        {room, displaced} <- choices(ctx, state, item, day, slot),
        reduce: found do
      found ->
        if System.monotonic_time(:millisecond) >= ctx.deadline, do: throw({:deadline, found})
        search(ctx, place(ctx, state, item, {day, slot, room}, displaced), found)
    end
  end

  # Rooms at one start with the placements each would displace. When a room is
  # free, occupied rooms only add moves, and free rooms in the same building
  # have the same cost.
  defp choices(ctx, state, item, day, slot) do
    time = occupants(ctx, state, item, day, slot, time_resources(item))

    if movable?(ctx, state, time) do
      rooms =
        for room <- item.rooms,
            external_free?(ctx, item, {day, slot, room}),
            do: {room, occupants(ctx, state, item, day, slot, room_resources(room)) -- time}

      case Enum.filter(rooms, fn {_room, extra} -> extra == [] end) do
        [] ->
          rooms
          |> Enum.map(fn {room, extra} -> {room, time ++ extra} end)
          |> Enum.filter(fn {_room, displaced} -> movable?(ctx, state, displaced) end)

        free ->
          free
          |> Enum.uniq_by(fn {room, _extra} -> ctx.buildings[room] end)
          |> Enum.map(fn {room, _extra} -> {room, time} end)
      end
    else
      []
    end
  end

  # The selected session stays at its target, and each placement moves at most once.
  defp movable?(ctx, state, displaced) do
    length(state.moved) + length(displaced) <= ctx.max_moves and
      Enum.all?(displaced, fn id ->
        id != ctx.selected and not ctx.items[id].locked and id not in state.moved
      end)
  end

  defp place(ctx, state, item, position, displaced) do
    index =
      Enum.reduce(displaced, state.index, fn id, index ->
        vacate(index, ctx.items[id], state.positions[id])
      end)

    %{
      state
      | positions: state.positions |> Map.drop(displaced) |> Map.put(item.id, position),
        index: occupy(index, item, position),
        moved: state.moved ++ displaced,
        queue: state.queue ++ displaced
    }
  end

  defp record(ctx, state, found) do
    target = state.positions[ctx.selected]
    moves = Enum.map(state.moved, &{&1, state.positions[&1]})

    Map.put_new_lazy(found, {target, Enum.sort(moves)}, fn ->
      %{
        target: target,
        moves: moves,
        penalty: penalty_change(ctx, state.positions, [ctx.selected | state.moved])
      }
    end)
  end

  defp rank(solution),
    do: {length(solution.moves), solution.penalty, solution.target, Enum.sort(solution.moves)}

  defp present(ctx, solution) do
    {day, slot, room} = solution.target

    moves =
      Enum.map(solution.moves, fn {id, {day, slot, room}} ->
        %{session: ctx.items[id].session, day: day, slot: slot, room: ctx.rooms[room]}
      end)

    %{
      room: ctx.rooms[room],
      moves: moves,
      groups:
        moves
        |> Enum.flat_map(& &1.session.cohorts)
        |> Enum.uniq_by(& &1.id)
        |> Enum.map(& &1.name)
        |> Enum.sort(),
      penalty: solution.penalty,
      changes: [
        %{
          session_id: ctx.selected,
          day: day,
          slot: slot,
          room_id: room,
          week_mask: ctx.items[ctx.selected].week_mask
        }
        | Enum.map(solution.moves, fn {id, {day, slot, room}} ->
            %{session_id: id, day: day, slot: slot, room_id: room}
          end)
      ]
    }
  end

  # Occupancy, keyed by {resource, day, slot}

  defp occupants(ctx, state, item, day, slot, resources) do
    for cell <- slot..(slot + item.duration - 1),
        resource <- resources,
        other <- Map.get(state.index, {resource, day, cell}, []),
        other != item.id,
        not MapSet.disjoint?(ctx.items[other].weeks, item.weeks),
        uniq: true,
        do: other
  end

  defp occupy(index, item, {day, slot, room}) do
    Enum.reduce(keys(item, day, slot, room), index, fn key, index ->
      Map.update(index, key, [item.id], &[item.id | &1])
    end)
  end

  defp vacate(index, item, {day, slot, room}) do
    Enum.reduce(keys(item, day, slot, room), index, fn key, index ->
      Map.update!(index, key, &List.delete(&1, item.id))
    end)
  end

  defp keys(item, day, slot, room) do
    for cell <- slot..(slot + item.duration - 1),
        resource <- time_resources(item) ++ room_resources(room),
        do: {resource, day, cell}
  end

  defp time_resources(item),
    do: [{:teacher, item.teacher} | Enum.map(item.cohorts, &{:cohort, &1})]

  defp room_resources(nil), do: []
  defp room_resources(room), do: [{:room, room}]

  defp external_free?(%{external: external}, _item, _position) when map_size(external) == 0,
    do: true

  defp external_free?(ctx, item, {day, slot, room}) do
    placement = %Placement{
      id: item.id,
      session_id: item.id,
      day: day,
      slot: slot,
      room_id: room,
      duration_slots: item.duration,
      week_mask: item.week_mask
    }

    not SharedResources.blocked?(ctx.external, ctx.term, item.session, placement)
  end

  # Soft penalty, as in priv/solver/solve.py. Only groups, days and pairs that
  # contain a changed session can differ, so the rest of the plan is skipped.

  defp penalty_change(ctx, positions, changed) do
    days =
      for id <- changed,
          position <- [ctx.before[id], positions[id]],
          position,
          uniq: true,
          do: elem(position, 0)

    classes =
      for id <- changed,
          subject <- time_resources(ctx.items[id]),
          {members, repetitions} <- ctx.classes[subject],
          id in members,
          uniq: true,
          do: {members, repetitions}

    pairs =
      for id <- changed,
          other <- ctx.partners[id],
          uniq: true,
          do: Enum.min_max([id, other])

    penalty(ctx, positions, changed, days, classes, pairs) -
      penalty(ctx, ctx.before, changed, days, classes, pairs)
  end

  defp penalty(ctx, positions, changed, days, classes, pairs) do
    weights = ctx.weights

    compact =
      for {members, repetitions} <- classes, day <- days, reduce: 0 do
        sum -> sum + repetitions * day_penalty(ctx, positions, members, day)
      end

    sequence =
      for {left, right} <- pairs,
          positions[left] && positions[right],
          reduce: 0 do
        sum -> sum + distance(ctx, left, positions[left], right, positions[right])
      end

    lost =
      for id <- changed,
          item = ctx.items[id],
          not item.session.automatic_weeks,
          {day, _slot, _room} <- [positions[id]],
          week <- item.week_mask,
          MapSet.member?(ctx.excluded, {week, day}),
          reduce: 0 do
        sum -> sum + 1
      end

    compact + weights.sequence * sequence + weights.excluded_days * lost
  end

  # The solver skips weekly groups with one session.
  defp day_penalty(_ctx, _positions, [_single], _day), do: 0

  defp day_penalty(ctx, positions, members, day) do
    placed =
      for id <- members, {^day, slot, room} <- [positions[id]], do: {ctx.items[id], slot, room}

    if placed == [] do
      0
    else
      cells =
        for {item, slot, _room} <- placed,
            cell <- slot..(slot + item.duration - 1),
            uniq: true,
            do: cell

      gaps =
        if ctx.slots_per_day >= 3,
          do: Enum.max(cells) - Enum.min(cells) + 1 - length(cells),
          else: 0

      buildings =
        placed
        |> Enum.map(fn {_item, _slot, room} -> ctx.buildings[room] end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> length()

      ctx.weights.gaps * gaps + ctx.weights.active_days +
        ctx.weights.building * max(buildings - 1, 0)
    end
  end

  # Zero when the blocks touch, otherwise the slots between them.
  defp distance(ctx, _left, {day, _, _}, _right, {other_day, _, _}) when day != other_day,
    do: ctx.slots_per_day

  defp distance(ctx, left, {_, slot, _}, right, {_, other_slot, _}) do
    left_end = slot + ctx.items[left].duration - 1
    right_end = other_slot + ctx.items[right].duration - 1

    cond do
      left_end + 1 == other_slot or right_end + 1 == slot -> 0
      left_end < other_slot -> other_slot - left_end
      right_end < slot -> slot - right_end
      true -> 1
    end
  end

  # Context

  defp context(session, plan_id, deadline) do
    term = Catalog.get_term!(session.term_id)
    grid = Config.grid!(term)
    rooms = Catalog.list_rooms()
    placements = Planning.list_placements(plan_id)
    current = Enum.find(placements, &(&1.session_id == session.id))
    others = Enum.reject(placements, &(&1.session_id == session.id))
    room_ids = Enum.map(rooms, & &1.id)

    items =
      [
        item(session, current, session.week_mask, room_ids)
        | Enum.map(others, &item(&1, room_ids))
      ]
      |> Map.new(&{&1.id, &1})

    before = Map.new(placements, &{&1.session_id, {&1.day, &1.slot, &1.room_id}})
    positions = Map.delete(before, session.id)

    %{
      selected: session.id,
      items: items,
      starts: Map.new(items, fn {id, item} -> {id, starts(term, grid, item)} end),
      before: before,
      positions: positions,
      index:
        Enum.reduce(positions, %{}, fn {id, position}, index ->
          occupy(index, items[id], position)
        end),
      rooms: Map.new(rooms, &{&1.id, &1}),
      buildings: Map.new(rooms, &{&1.id, &1.building_id}),
      classes: classes(items),
      partners: partners(items),
      excluded: excluded(term, grid),
      weights: Soft.weights(),
      slots_per_day: length(grid.slots),
      external: SharedResources.external_index(term),
      term: term,
      deadline: deadline,
      max_moves: 0
    }
  end

  defp item(placement, room_ids),
    do: item(placement.session, placement, placement.week_mask, room_ids)

  defp item(session, placement, week_mask, room_ids) do
    allowed =
      case session.course_component.allowed_rooms do
        [] -> room_ids
        rooms -> Enum.map(rooms, & &1.id)
      end

    # The current room comes first, so a free room keeps the session where it is.
    current = placement && placement.room_id

    %{
      id: session.id,
      session: session,
      locked: placement != nil and placement.locked,
      week_mask: week_mask,
      weeks: MapSet.new(week_mask),
      duration: session.duration_slots || 1,
      teacher: session.teacher_id,
      cohorts: Enum.map(session.cohorts, & &1.id),
      rooms:
        if(session.delivery_mode == :online,
          do: [nil],
          else: Enum.sort_by(allowed, &(&1 != current))
        )
    }
  end

  # The restrictions that do not depend on other placements, as in Feasibility.
  defp starts(term, grid, item) do
    days = length(grid.days)
    last = length(grid.slots) - item.duration + 1

    cells =
      case item.session.slot_profile do
        nil ->
          for day <- 1..days, slot <- 1..max(last, 0)//1, do: {day, slot}

        profile ->
          profile.cells
          |> Enum.filter(&(&1.day <= days and &1.slot <= last))
          |> Enum.map(&{&1.day, &1.slot})
          |> Enum.uniq()
      end

    # An empty allow-list means unrestricted, not unavailable.
    available =
      case Enum.filter(item.session.teacher.availability_cells || [], &(&1.term_id == term.id)) do
        [] -> nil
        cells -> MapSet.new(cells, &{&1.day, &1.slot})
      end

    Enum.filter(cells, fn {day, slot} ->
      (is_nil(available) or
         Enum.all?(slot..(slot + item.duration - 1), &MapSet.member?(available, {day, &1}))) and
        AutomaticWeeks.errors(term, [
          %{
            id: nil,
            session_id: item.id,
            session: item.session,
            week_mask: item.week_mask,
            day: day
          }
        ]) == []
    end)
  end

  # Weekly groups of each teacher and group, with their number of weeks. Weeks
  # with the same sessions share one entry, as in the solver.
  defp classes(items) do
    items
    |> Map.values()
    |> Enum.flat_map(fn item ->
      for subject <- time_resources(item), week <- item.week_mask, do: {{subject, week}, item.id}
    end)
    |> Enum.group_by(fn {key, _id} -> key end, fn {_key, id} -> id end)
    |> Enum.group_by(fn {{subject, _week}, _ids} -> subject end, fn {_key, ids} ->
      Enum.sort(ids)
    end)
    |> Map.new(fn {subject, groups} -> {subject, Map.to_list(Enum.frequencies(groups))} end)
  end

  defp partners(items) do
    related =
      items
      |> Map.values()
      |> Enum.reject(&is_nil(&1.session.sequence_group))
      |> Enum.group_by(& &1.session.sequence_group)

    Map.new(items, fn {id, item} ->
      partners =
        for other <- Map.get(related, item.session.sequence_group, []),
            other.id != id,
            not MapSet.disjoint?(other.weeks, item.weeks),
            do: other.id

      {id, partners}
    end)
  end

  # Week and day cells without teaching, as the solver receives them.
  defp excluded(term, grid) do
    for week <- 1..term.weeks_count//1,
        day <- 1..length(grid.days),
        date = TermDates.date(term, week, day),
        not TermDates.within?(term, date) or date in (term.excluded_dates || []),
        into: MapSet.new(),
        do: {week, day}
  end
end
