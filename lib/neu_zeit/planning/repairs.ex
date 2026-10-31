defmodule NeuZeit.Planning.Repairs do
  @moduledoc """
  Suggests repairs for a start that other placements block.

  A repair places the selected session at the start and moves other unlocked
  placements, so that the result passes the hard checks. Locked placements
  never move. The search follows the suggestions of UniTime (Müller, Murray and
  Rudová, PATAT 2010): depth-first, limited by moves and by time. It allows one
  move, then two, and more only while no repair is found.

  Repairs are ranked by moves, then by the change in the soft penalty that the
  solver minimizes: gaps, active days, buildings per day, related blocks,
  meetings lost on non-teaching dates and the times and rooms that each
  requirement's generated meetings use. Week sets never change.
  """

  alias NeuZeit.{Catalog, Config, Planning}
  alias NeuZeit.Constraints.{AutomaticWeeks, Soft}
  alias NeuZeit.Planning.{Placement, SharedResources}
  alias NeuZeit.Scheduling.TermDates

  # Each added move multiplies the search. With seven, a start that no repair
  # frees on a board of 600 sessions is settled well within the time limit.
  @max_moves 7

  @doc "The most moves of other placements a repair has by default."
  def max_moves, do: @max_moves

  @doc """
  Returns repairs for placing `session` at `{day, slot}`.

  The result is `%{repairs: repairs, complete: boolean}`.
  `complete` is false when `:timeout` (milliseconds, default 5000) ended the
  search before every option that could change the result was checked.
  Options: `:max_moves` (default `max_moves/0`) and `:limit` (default 5). The
  caller passes the session with the week set it is edited for, as
  `Feasibility.cells_for/3` expects.

  Each repair has the session's `room`, the other `moves`, the affected
  `groups`, the soft `penalty` change (lower is better) and the `changes` for
  `NeuZeit.Planning.change_placements/2`. `explored` counts the placements the
  search tried.
  """
  def suggest(session, plan_id, day, slot, opts \\ []) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, 5_000)
    search(board(session, plan_id), session, day, slot, Keyword.put(opts, :deadline, deadline))
  end

  @doc false
  # What the search reads from the database, so a benchmark can replay it.
  def board(session, plan_id) do
    term = Catalog.get_term!(session.term_id)

    %{
      term: term,
      rooms: Catalog.list_rooms(),
      placements: Planning.list_placements(plan_id),
      external: SharedResources.external_index(term)
    }
  end

  @doc false
  # Searches a loaded board until `:deadline`, in monotonic milliseconds.
  def search(board, session, day, slot, opts) do
    ctx = context(board, session, Keyword.fetch!(opts, :deadline))
    limit = Keyword.get(opts, :limit, 5)

    {{solutions, _cache}, complete} =
      deepen(ctx, day, slot, 1, {%{}, %{}}, Keyword.get(opts, :max_moves, @max_moves), limit)

    %{
      repairs:
        solutions
        |> Map.values()
        |> Enum.sort_by(&rank/1)
        |> Enum.take(limit)
        |> Enum.map(&present(ctx, &1)),
      complete: complete,
      explored: :counters.get(ctx.explored, 1)
    }
  end

  # Search

  # One move first, so a short limit still returns the smallest repairs.
  # Repairs with more moves rank after those found, so a deeper pass runs only
  # while fewer than `limit` were found, and past two moves only while none was.
  # A pass that never reached its move budget has seen every repair there is.
  defp deepen(ctx, day, slot, moves, {solutions, _cache} = found, max_moves, limit) do
    if moves > max_moves or map_size(solutions) >= limit or
         (moves > 2 and map_size(solutions) > 0) do
      {found, true}
    else
      :counters.put(ctx.cut, 1, 0)

      case explore(%{ctx | max_moves: moves}, day, slot, found) do
        {:stopped, found} ->
          {found, false}

        {:done, found} ->
          if :counters.get(ctx.cut, 1) == 0,
            do: {found, true},
            else: deepen(ctx, day, slot, moves + 1, found, max_moves, limit)
      end
    end
  end

  defp explore(ctx, day, slot, found) do
    selected = ctx.items[ctx.selected]
    state = %{positions: ctx.positions, index: ctx.index, moved: [], queue: []}

    choices =
      if not selected.locked and {day, slot} in starts(ctx, selected),
        do: choices(ctx, state, selected, day, slot),
        else: []

    # A free room needs no repair. The inspector offers it directly.
    found =
      if Enum.any?(choices, fn {_room, displaced, _shifts} -> displaced == [] end) do
        found
      else
        Enum.reduce(choices, found, fn {room, displaced, shifts}, found ->
          search(ctx, place(ctx, state, selected, {day, slot, room}, displaced, shifts), found)
        end)
      end

    {:done, found}
  catch
    {:deadline, found} -> {:stopped, found}
  end

  defp search(ctx, %{queue: []} = state, found), do: record(ctx, state, found)

  defp search(ctx, %{queue: [id | queue]} = state, found)
       when ctx.max_moves > 2 and queue != [] do
    item = ctx.items[id]
    search_starts(ctx, %{state | queue: queue}, item, starts(ctx, item), found, true)
  end

  defp search(ctx, %{queue: [id | queue]} = state, found) do
    item = ctx.items[id]
    state = %{state | queue: queue}

    for {day, slot} <- starts(ctx, item),
        {room, displaced, shifts} <- choices(ctx, state, item, day, slot),
        reduce: found do
      found ->
        if System.monotonic_time(:millisecond) >= ctx.deadline, do: throw({:deadline, found})
        search(ctx, place(ctx, state, item, {day, slot, room}, displaced, shifts), found)
    end
  end

  # Deep passes cut a state once another queued session has no choice: moves
  # cannot give it one, as vacating a blocker uses the move it saves. Sessions
  # keep their FIFO order, since the room shortcut in choices/5 depends on it.
  defp search_starts(_ctx, _state, _item, [], found, _check?), do: found

  defp search_starts(ctx, state, item, [{day, slot} | starts], found, check?) do
    options = choices(ctx, state, item, day, slot)

    cond do
      options == [] ->
        search_starts(ctx, state, item, starts, found, check?)

      check? and not Enum.all?(state.queue, &placeable?(ctx, state, &1, found)) ->
        found

      true ->
        found =
          Enum.reduce(options, found, fn {room, displaced, shifts}, found ->
            if System.monotonic_time(:millisecond) >= ctx.deadline, do: throw({:deadline, found})
            search(ctx, place(ctx, state, item, {day, slot, room}, displaced, shifts), found)
          end)

        search_starts(ctx, state, item, starts, found, false)
    end
  end

  defp placeable?(ctx, state, id, found) do
    item = ctx.items[id]

    Enum.any?(starts(ctx, item), fn {day, slot} ->
      if System.monotonic_time(:millisecond) >= ctx.deadline, do: throw({:deadline, found})
      choices(ctx, state, item, day, slot) != []
    end)
  end

  # Rooms at one start with the placements each would displace and the placed
  # sessions it would shift to another room. When a room is free, occupied
  # rooms only add moves. Free rooms in one building have the same cost unless
  # another meeting of the requirement is held in one at that time, so one of
  # each kind is kept, preferably one that shifts no session.
  defp choices(ctx, state, item, day, slot) do
    time = occupants(ctx, state, item, day, slot, time_resources(item))

    if movable?(ctx, state, time) do
      rooms =
        for room <- item.rooms,
            external_free?(ctx, item, {day, slot, room}),
            choice = room_choice(ctx, state, item, {day, slot, room}, time),
            do: choice

      case Enum.filter(rooms, fn {_room, extra, _shifts} -> extra == [] end) do
        [] ->
          rooms
          |> Enum.map(fn {room, extra, shifts} -> {room, time ++ extra, shifts} end)
          |> Enum.filter(fn {_room, displaced, _shifts} -> movable?(ctx, state, displaced) end)

        free ->
          shared = shared(ctx, state, item, {day, slot})

          free
          |> Enum.sort_by(fn {_room, _extra, shifts} -> shifts != [] end)
          |> Enum.uniq_by(fn {room, _extra, _shifts} -> {ctx.buildings[room], room in shared} end)
          |> Enum.map(fn {room, _extra, shifts} -> {room, time, shifts} end)
      end
    else
      []
    end
  end

  # A room with its other occupants, less the placed sessions among them, which
  # shift to another room. Nil when one of those cannot.
  defp room_choice(ctx, state, item, {day, slot, room}, time) do
    case occupants(ctx, state, item, day, slot, room_resources(room)) -- time do
      [] ->
        {room, [], []}

      extra ->
        {placed, extra} = Enum.split_with(extra, &placed?(ctx, state, &1))
        if shifts = shifts(ctx, state, placed, room), do: {room, extra, shifts}
    end
  end

  defp placed?(ctx, state, id), do: id == ctx.selected or id in state.moved

  # A session this repair already placed can leave a room for another free room
  # of its building, so the room a free choice took does not block later moves.
  # Nil when one of them cannot.
  defp shifts(_ctx, _state, [], _room), do: []

  defp shifts(ctx, state, placed, room) do
    Enum.reduce_while(placed, {state.index, []}, fn id, {index, shifts} ->
      item = ctx.items[id]
      {day, slot, ^room} = position = state.positions[id]
      index = vacate(index, item, position)

      free =
        Enum.find(item.rooms, fn other ->
          other != room and ctx.buildings[other] == ctx.buildings[room] and
            external_free?(ctx, item, {day, slot, other}) and
            occupants(ctx, %{state | index: index}, item, day, slot, room_resources(other)) == []
        end)

      if free,
        do: {:cont, {occupy(index, item, {day, slot, free}), [{id, free} | shifts]}},
        else: {:halt, nil}
    end)
    |> case do
      {_index, shifts} -> Enum.reverse(shifts)
      nil -> nil
    end
  end

  # Rooms where another meeting of the item's requirement is held at the start.
  defp shared(ctx, state, %{session: %{automatic_weeks: true}} = item, {day, slot}) do
    for id <- ctx.meetings[ctx.workloads[item.id]],
        id != item.id,
        {^day, ^slot, room} <- [state.positions[id]],
        do: room
  end

  defp shared(_ctx, _state, _item, _start), do: []

  # The selected session stays at its target, and each placement moves at most
  # once. A choice over the move budget is counted, since a deeper pass takes it.
  defp movable?(ctx, state, displaced) do
    cond do
      not Enum.all?(displaced, fn id ->
        id != ctx.selected and not ctx.items[id].locked and id not in state.moved
      end) ->
        false

      length(state.moved) + length(displaced) <= ctx.max_moves ->
        true

      true ->
        :counters.add(ctx.cut, 1, 1)
        false
    end
  end

  defp place(ctx, state, item, position, displaced, shifts) do
    :counters.add(ctx.explored, 1, 1)

    index =
      Enum.reduce(displaced, state.index, fn id, index ->
        vacate(index, ctx.items[id], state.positions[id])
      end)

    {index, positions} =
      Enum.reduce(shifts, {index, state.positions}, fn {id, room}, {index, positions} ->
        {day, slot, _room} = old = positions[id]
        index = index |> vacate(ctx.items[id], old) |> occupy(ctx.items[id], {day, slot, room})
        {index, Map.put(positions, id, {day, slot, room})}
      end)

    %{
      state
      | positions: positions |> Map.drop(displaced) |> Map.put(item.id, position),
        index: occupy(index, item, position),
        moved: state.moved ++ displaced,
        queue: state.queue ++ displaced
    }
  end

  defp record(ctx, state, {solutions, cache} = found) do
    target = state.positions[ctx.selected]
    moves = Enum.map(state.moved, &{&1, state.positions[&1]})
    key = {target, Enum.sort(moves)}

    if Map.has_key?(solutions, key) do
      found
    else
      {penalty, cache} = penalty_change(ctx, state.positions, [ctx.selected | state.moved], cache)
      {Map.put(solutions, key, %{target: target, moves: moves, penalty: penalty}), cache}
    end
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

  defp external_free?(ctx, item, {day, _slot, room} = position) do
    # Grid days are weekdays. A miss cannot overlap any projected occurrence.
    booked? =
      MapSet.member?(ctx.external_days, {"room", room, day}) or
        MapSet.member?(ctx.external_days, {"teacher", item.teacher, day}) or
        Enum.any?(item.cohorts, &MapSet.member?(ctx.external_days, {"cohort", &1, day}))

    not booked? or projected_free?(ctx, item, position)
  end

  defp projected_free?(ctx, item, {day, slot, room}) do
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

  defp penalty_change(ctx, positions, changed, cache) do
    # A weekly group changes only on the days its changed sessions leave or
    # take. The solver weighs identical groups of a teacher and a group
    # separately.
    class_days =
      for id <- changed,
          subject <- time_resources(ctx.items[id]),
          {index, members, repetitions} <- ctx.classes[subject],
          length(members) > 1,
          id in members,
          position <- [ctx.before[id], positions[id]],
          position,
          reduce: %{} do
        days ->
          key = {index, members, repetitions, elem(position, 0)}
          Map.update(days, key, [id], &Enum.uniq([id | &1]))
      end

    # Cache only days that a repair touches, including across deeper passes.
    {compact, cache} =
      Enum.reduce(class_days, {0, cache}, fn {{index, members, repetitions, day}, ids},
                                             {sum, cache} ->
        key = {index, day}

        cache =
          Map.put_new_lazy(cache, key, fn ->
            base =
              Enum.reduce(members, {%{}, %{}}, fn id, acc ->
                shift_day(ctx, day, acc, id, Map.get(ctx.before, id), 1)
              end)

            {day_penalty(ctx, base), base}
          end)

        {before, base} = Map.fetch!(cache, key)

        after_day =
          Enum.reduce(ids, base, fn id, acc ->
            acc = shift_day(ctx, day, acc, id, Map.get(ctx.before, id), -1)
            shift_day(ctx, day, acc, id, Map.get(positions, id), 1)
          end)

        delta = day_penalty(ctx, after_day) - before
        {sum + repetitions * delta, cache}
      end)

    pairs =
      for id <- changed,
          other <- ctx.partners[id],
          uniq: true,
          do: Enum.min_max([id, other])

    requirements = for id <- changed, key = ctx.workloads[id], uniq: true, do: key

    {compact + penalty(ctx, positions, changed, pairs, requirements) -
       penalty(ctx, ctx.before, changed, pairs, requirements), cache}
  end

  defp penalty(ctx, positions, changed, pairs, requirements) do
    weights = ctx.weights

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

    weights.sequence * sequence + weights.excluded_days * lost +
      recurring(ctx, positions, requirements)
  end

  # The solver counts each time and room a requirement's generated meetings
  # use, unweighted.
  defp recurring(ctx, positions, requirements) do
    for key <- requirements, reduce: 0 do
      sum ->
        sum + (ctx.meetings[key] |> Enum.map(&positions[&1]) |> Enum.uniq() |> Enum.count(& &1))
    end
  end

  # Counts preserve overlapping spans and buildings shared by several members.
  defp shift_day(ctx, day, {cells, buildings}, id, {day, slot, room}, amount) do
    %{duration: duration} = Map.fetch!(ctx.items, id)
    cells = Enum.reduce(slot..(slot + duration - 1), cells, &count(&2, &1, amount))
    building = Map.get(ctx.buildings, room)
    buildings = if is_nil(building), do: buildings, else: count(buildings, building, amount)
    {cells, buildings}
  end

  defp shift_day(_ctx, _day, acc, _id, _position, _amount), do: acc

  defp count(counts, key, amount) do
    case Map.get(counts, key, 0) + amount do
      0 -> Map.delete(counts, key)
      value -> Map.put(counts, key, value)
    end
  end

  defp day_penalty(_ctx, {cells, _buildings}) when map_size(cells) == 0, do: 0

  defp day_penalty(ctx, {cells, buildings}) do
    {first, last} =
      Enum.reduce(cells, {nil, nil}, fn {cell, _count}, {first, last} ->
        {min(first || cell, cell), max(last || cell, cell)}
      end)

    gaps = if ctx.slots_per_day >= 3, do: last - first + 1 - map_size(cells), else: 0

    ctx.weights.gaps * gaps + ctx.weights.active_days +
      ctx.weights.building * max(map_size(buildings) - 1, 0)
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

  defp context(%{term: term, rooms: rooms, placements: placements} = board, session, deadline) do
    grid = Config.grid!(term)
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
    eligible = eligible(items, placements)
    workloads = workloads(items, eligible)

    %{
      selected: session.id,
      items: items,
      grid: grid,
      before: before,
      positions: positions,
      index:
        Enum.reduce(positions, %{}, fn {id, position}, index ->
          occupy(index, items[id], position)
        end),
      rooms: Map.new(rooms, &{&1.id, &1}),
      buildings: Map.new(rooms, &{&1.id, &1.building_id}),
      classes: classes(items),
      partners: partners(items, eligible),
      workloads: workloads,
      meetings: Enum.group_by(Map.keys(workloads), &workloads[&1]),
      excluded: excluded(term, grid),
      weights: Soft.weights(),
      slots_per_day: length(grid.slots),
      external: board.external,
      external_days:
        MapSet.new(Map.keys(board.external), fn {date, kind, id} ->
          {kind, id, Date.day_of_week(date)}
        end),
      term: term,
      deadline: deadline,
      explored: :counters.new(1, []),
      cut: :counters.new(1, []),
      max_moves: 0
    }
  end

  defp item(placement, room_ids),
    do: item(placement.session, placement, placement.week_mask, room_ids)

  defp item(session, placement, week_mask, room_ids) do
    # Sorted, as the database returns allowed rooms in no fixed order.
    allowed =
      case session.course_component.allowed_rooms do
        [] -> room_ids
        rooms -> rooms |> Enum.map(& &1.id) |> Enum.sort()
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
  # Computed when a session moves, since most never do.
  defp starts(%{term: term, grid: grid}, item) do
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

    teaching =
      for day <- 1..days,
          AutomaticWeeks.errors(term, [
            %{
              id: nil,
              session_id: item.id,
              session: item.session,
              week_mask: item.week_mask,
              day: day
            }
          ]) == [],
          do: day

    Enum.filter(cells, fn {day, slot} ->
      day in teaching and
        (is_nil(available) or
           Enum.all?(slot..(slot + item.duration - 1), &MapSet.member?(available, {day, &1})))
    end)
  end

  # Weekly groups of each teacher and group, with their number of weeks. Weeks
  # with the same sessions share one entry, as in the solver. One walk lists
  # every week's sessions in the same order, so equal weeks compare equal.
  defp classes(items) do
    subjects =
      for {id, item} <- items, subject <- time_resources(item), reduce: %{} do
        subjects ->
          weeks =
            for week <- item.week_mask, reduce: Map.get(subjects, subject, %{}) do
              weeks -> Map.update(weeks, week, [id], &[id | &1])
            end

          Map.put(subjects, subject, weeks)
      end

    subjects
    |> Enum.flat_map(fn {subject, weeks} ->
      for {members, repetitions} <- Enum.frequencies(Map.values(weeks)),
          do: {subject, members, repetitions}
    end)
    |> Enum.with_index()
    |> Enum.group_by(fn {{subject, _members, _repetitions}, _index} -> subject end, fn
      {{_subject, members, repetitions}, index} -> {index, members, repetitions}
    end)
  end

  # The weeks each session has in the solver's contract. A generated meeting is
  # held in one of its requirement's weeks; the selected one comes with the
  # week it is edited for, so its requirement's weeks come from a placed
  # meeting of its workload.
  defp eligible(items, placements) do
    weeks = Map.new(placements, &{&1.session.workload_id, &1.session.week_mask})

    Map.new(items, fn
      {id, %{session: %{automatic_weeks: true} = session}} ->
        {id, MapSet.new(Map.get(weeks, session.workload_id, session.week_mask))}

      {id, item} ->
        {id, item.weeks}
    end)
  end

  # Generated meetings by requirement, keyed as SpecBuilder keys them.
  defp workloads(items, eligible) do
    for {id, %{session: %{automatic_weeks: true} = session}} <- items, into: %{} do
      {id,
       {session.course_component_id, session.teacher_id,
        Enum.sort(Enum.map(session.cohorts, & &1.id)), session.duration_slots,
        session.slot_profile_id, Enum.sort(eligible[id]), session.delivery_mode}}
    end
  end

  # The solver relates the blocks of a sequence group whose weeks overlap,
  # counting all weeks a generated meeting may be held in.
  defp partners(items, eligible) do
    related =
      items
      |> Map.values()
      |> Enum.reject(&is_nil(&1.session.sequence_group))
      |> Enum.group_by(& &1.session.sequence_group)

    Map.new(items, fn {id, item} ->
      partners =
        for other <- Map.get(related, item.session.sequence_group, []),
            other.id != id,
            not MapSet.disjoint?(eligible[other.id], eligible[id]),
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
