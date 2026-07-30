defmodule NeuZeit.Solver.SpecBuilder do
  @moduledoc """
  Builds the normalized JSON contract consumed by the Python solver.
  """

  import Ecto.Query, warn: false

  alias NeuZeit.Catalog.{Room, Session, TeacherAvailabilityCell}
  alias NeuZeit.Config
  alias NeuZeit.Constraints.{Hard, Soft}
  alias NeuZeit.Planning.{Placement, Plan}
  alias NeuZeit.Repo

  def build!(plan_id) do
    config = Config.load!()

    plan =
      Plan
      |> Repo.get!(plan_id)
      |> Repo.preload(:term)

    rooms = Repo.all(from r in Room, order_by: r.id, preload: [:building])

    sessions =
      Repo.all(
        from s in Session,
          where: s.term_id == ^plan.term_id,
          order_by: s.id,
          preload: [
            :cohorts,
            teacher: [:availability_cells],
            slot_profile: [:cells],
            course_component: [:allowed_rooms]
          ]
      )

    placements =
      Repo.all(
        from p in Placement,
          where: p.plan_id == ^plan.id,
          preload: [:session]
      )

    room_specs = Enum.map(rooms, &room_spec/1)
    session_specs = Enum.map(sessions, &session_spec(&1, config.grid))

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

  # Term excluded dates and teaching-day cells after a partial final week are
  # mapped onto the grid so the solver avoids placements that lose meetings.
  defp excluded_cells(term, config) do
    days_count = length(config.grid.days)

    excluded_dates = Enum.map(term.excluded_dates || [], &cell(term, &1))

    final_week_start = Date.add(term.starts_on, (term.weeks_count - 1) * 7)

    partial_final_week =
      1..days_count
      |> Enum.map(fn day -> {day, Date.add(final_week_start, day - 1)} end)
      |> Enum.filter(fn {_day, date} -> Date.after?(date, term.ends_on) end)
      |> Enum.map(fn {day, _date} -> %{week: term.weeks_count, day: day} end)

    (excluded_dates ++ partial_final_week)
    |> Enum.filter(&(&1.week >= 1 and &1.week <= term.weeks_count and &1.day <= days_count))
    |> Enum.uniq()
    |> Enum.sort_by(&{&1.week, &1.day})
  end

  defp cell(term, date) do
    %{
      week: div(Date.diff(date, term.starts_on), 7) + 1,
      day: Date.day_of_week(date)
    }
  end

  defp room_spec(room) do
    %{id: to_string(room.id), building_id: to_string(room.building_id)}
  end

  defp session_spec(session, grid) do
    %{
      id: to_string(session.id),
      teacher: to_string(session.teacher_id),
      cohorts: Enum.map(session.cohorts, &to_string(&1.id)),
      allowed_rooms: Enum.map(session.course_component.allowed_rooms, &to_string(&1.id)),
      allowed_starts: allowed_starts(session, grid),
      duration_slots: session.duration_slots,
      weeks: session.week_mask,
      sequence_group: session.sequence_group
    }
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
       %{day: placement.day, slot: placement.slot, room: to_string(placement.room_id)}}
    end)
  end
end
