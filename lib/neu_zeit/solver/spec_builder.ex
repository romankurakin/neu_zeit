defmodule NeuZeit.Solver.SpecBuilder do
  alias NeuZeit.Scheduling.TermDates

  @moduledoc """
  Builds the normalized JSON contract consumed by the Python solver.
  """

  alias NeuZeit.Catalog.TeacherAvailabilityCell
  alias NeuZeit.Catalog.DeliveryMode
  alias NeuZeit.Constraints.{Hard, Soft}
  alias NeuZeit.Planning.Placement
  alias NeuZeit.Solver.Snapshot

  def build!(plan_id), do: plan_id |> Snapshot.load!() |> build()

  @doc "Builds the solver contract from a loaded snapshot without database access."
  def build(%{
        plan: plan,
        rooms: rooms,
        sessions: sessions,
        placements: placements,
        external: external,
        config: config
      }) do
    room_specs = Enum.map(rooms, &room_spec/1)

    session_specs =
      Enum.map(sessions, fn session ->
        spec = session_spec(session, config.grid, rooms)

        masks =
          if session.automatic_weeks,
            do: Enum.map(session.week_mask, &[&1]),
            else: [session.week_mask]

        blocked =
          for mask <- masks,
              start <- spec.allowed_starts,
              room <- DeliveryMode.room_options(session.delivery_mode, spec.allowed_rooms),
              placement = %Placement{
                id: session.id,
                session_id: session.id,
                day: start.day,
                slot: start.slot,
                room_id: room,
                week_mask: mask,
                duration_slots: session.duration_slots
              },
              NeuZeit.Planning.SharedResources.blocked?(external, plan.term, session, placement) do
            cell = %{day: start.day, slot: start.slot, room: room}
            if session.automatic_weeks, do: Map.put(cell, :week, hd(mask)), else: cell
          end

        Map.put(spec, :blocked_assignments, blocked)
      end)

    %{
      grid: %{
        days_count: length(config.grid.days),
        slots_per_day: length(config.grid.slots)
      },
      excluded_cells: excluded_cells(plan.term, config),
      rooms: room_specs,
      sessions: session_specs,
      fixed: placement_map(Enum.filter(placements, & &1.locked)),
      current: placement_map(placements),
      hard: Hard.solver_rules(session_specs, room_specs),
      soft: Soft.solver_rules(session_specs, config),
      requirements: %{all_sessions_placed: config.solver.require_complete_solution},
      solver: %{
        time_limit: config.solver.time_limit,
        gap: config.solver.gap,
        workers: config.solver.workers
      }
    }
  end

  # Boundary weeks can be partial at either end of the term.
  defp excluded_cells(term, config) do
    days_count = length(config.grid.days)

    excluded_dates = Enum.map(term.excluded_dates || [], &cell(term, &1))

    boundary_cells =
      for week <- Enum.uniq([1, term.weeks_count]),
          day <- 1..days_count,
          not TermDates.within?(term, TermDates.date(term, week, day)),
          do: %{week: week, day: day}

    (excluded_dates ++ boundary_cells)
    |> Enum.filter(&(&1.week >= 1 and &1.week <= term.weeks_count and &1.day <= days_count))
    |> Enum.uniq()
    |> Enum.sort_by(&{&1.week, &1.day})
  end

  defp cell(term, date) do
    %{
      week: TermDates.week(term, date),
      day: Date.day_of_week(date)
    }
  end

  defp room_spec(room) do
    %{id: to_string(room.id), building_id: to_string(room.building_id)}
  end

  defp session_spec(session, grid, rooms) do
    %{
      id: to_string(session.id),
      teacher: to_string(session.teacher_id),
      cohorts: Enum.map(session.cohorts, &to_string(&1.id)),
      delivery_mode: session.delivery_mode,
      allowed_rooms:
        if(DeliveryMode.physical?(session.delivery_mode),
          do:
            Enum.map(
              NeuZeit.Catalog.CourseComponent.room_options(session.course_component, rooms),
              &to_string(&1.id)
            ),
          else: []
        ),
      allowed_starts: allowed_starts(session, grid),
      duration_slots: session.duration_slots,
      weeks: session.week_mask,
      sequence_group: session.sequence_group
    }
    |> then(fn spec ->
      if session.automatic_weeks do
        key =
          {session.course_component_id, session.teacher_id,
           Enum.sort(Enum.map(session.cohorts, & &1.id)), session.duration_slots,
           session.slot_profile_id, session.week_mask, session.delivery_mode}

        Map.merge(spec, %{
          choose_week: true,
          workload: key |> :erlang.term_to_binary() |> Base.encode64()
        })
      else
        spec
      end
    end)
  end

  defp allowed_starts(session, grid) do
    days_count = length(grid.days)
    slots_count = length(grid.slots)
    last_start = slots_count - session.duration_slots + 1

    cells =
      case session.slot_profile do
        %{cells: cells} -> Enum.map(cells, &%{day: &1.day, slot: &1.slot})
        _ -> for day <- 1..days_count, slot <- 1..slots_count, do: %{day: day, slot: slot}
      end

    if last_start < 1 do
      []
    else
      cells
      |> Enum.filter(&(&1.day in 1..days_count and &1.slot in 1..last_start))
      |> Enum.filter(&teacher_available?(session, &1))
      |> Enum.uniq()
      |> Enum.sort_by(&{&1.day, &1.slot})
    end
  end

  defp teacher_available?(session, start) do
    cells =
      case session.teacher do
        %{availability_cells: cells} when is_list(cells) ->
          Enum.filter(cells, &(&1.term_id == session.term_id))

        _ ->
          []
      end

    TeacherAvailabilityCell.unavailable_slots(
      cells,
      start.day,
      start.slot,
      session.duration_slots
    ) == []
  end

  defp placement_map(placements) do
    Map.new(placements, fn placement ->
      {to_string(placement.session_id),
       %{day: placement.day, slot: placement.slot, room: encode_room(placement.room_id)}
       |> then(fn value ->
         if Map.get(placement.session, :automatic_weeks, false),
           do: Map.put(value, :weeks, placement.week_mask),
           else: value
       end)}
    end)
  end

  defp encode_room(nil), do: nil
  defp encode_room(room_id), do: to_string(room_id)
end
