defmodule NeuZeit.Planning.Feasibility do
  @moduledoc """
  Finds allowed session positions before a placement is saved.

  Uses the same restrictions as hard checks: grid bounds, time profile, teacher
  availability, allowed rooms and resource conflicts. Includes published bookings
  from other terms.
  """

  import Ecto.Query

  alias NeuZeit.Catalog.{DeliveryMode, TeacherAvailabilityCell, WeekPattern}
  alias NeuZeit.Config
  alias NeuZeit.Planning.Placement
  alias NeuZeit.Repo

  @doc """
  Returns allowed starts as `%{{day, slot} => [room_id]}`.

  Each cell fits the full session and has at least one allowed free room.
  Ignores this session's existing placement when evaluating alternatives.
  """
  def cells_for(session, plan_id, opts \\ []) do
    grid = Keyword.get(opts, :grid, Config.grid!(session.term_id))
    others = other_placements(plan_id, session.id)

    duration = session.duration_slots || 1
    slots = length(grid.slots)
    days = length(grid.days)

    busy = busy_index(others, session)
    occupied_rooms = room_index(others)

    allowed_rooms =
      DeliveryMode.room_options(
        session.delivery_mode,
        Enum.map(NeuZeit.Catalog.available_rooms(session.course_component), & &1.id)
      )

    availability = term_availability(session)
    term = NeuZeit.Catalog.get_term!(session.term_id)
    external = NeuZeit.Planning.SharedResources.external_index(term)

    for start <- starts(session, days, slots, duration),
        {day, slot} = start,
        cells = Enum.to_list(slot..(slot + duration - 1)),
        available?(availability, day, cells),
        not resource_busy?(busy, day, cells, session.week_mask),
        rooms = free_rooms(allowed_rooms, occupied_rooms, day, cells, session.week_mask),
        rooms =
          Enum.reject(rooms, fn room ->
            p = %Placement{
              id: session.id,
              session_id: session.id,
              day: day,
              slot: slot,
              room_id: room,
              duration_slots: duration,
              week_mask: session.week_mask
            }

            NeuZeit.Planning.SharedResources.blocked?(external, term, session, p)
          end),
        rooms != [],
        into: %{} do
      {start, rooms}
    end
  end

  @doc """
  Returns the rules that apply to an existing placement for display in its inspector.
  """
  def explain(placement, plan_id, opts \\ []) do
    # Load required associations here so callers can pass sessions from any screen.
    session = NeuZeit.Catalog.get_session!(placement.session_id)

    session =
      if session.automatic_weeks, do: %{session | week_mask: placement.week_mask}, else: session

    grid = Keyword.get(opts, :grid, Config.grid!(session.term_id))
    legal = cells_for(session, plan_id, grid: grid)

    explain_session(session, placement, legal)
  end

  def explain_session(session, placement, legal) do
    %{
      locked: placement && placement.locked,
      slot_profile: profile_reason(session),
      availability: availability_reason(session),
      room_pool: %{
        course_id: session.course_component.course_id,
        component_id: session.course_component_id,
        rooms:
          if(DeliveryMode.physical?(session.delivery_mode),
            do:
              Enum.map(
                NeuZeit.Catalog.available_rooms(session.course_component),
                &%{
                  id: &1.id,
                  name: &1.name
                }
              ),
            else: []
          )
      },
      alternatives: map_size(legal),
      alternative_rooms_here:
        if(placement, do: Map.get(legal, {placement.day, placement.slot}, []), else: []),
      week_mask: session.week_mask
    }
  end

  @doc "Read-only validation of each room at a proposed start, using the write-path rules."
  def assess(session, plan_id, day, slot) do
    others =
      NeuZeit.Planning.list_placements(plan_id) |> Enum.reject(&(&1.session_id == session.id))

    term = NeuZeit.Catalog.get_term!(session.term_id)
    external = NeuZeit.Planning.SharedResources.external_index(term)

    rooms =
      DeliveryMode.room_options(
        session.delivery_mode,
        NeuZeit.Catalog.available_rooms(session.course_component)
      )

    Enum.map(rooms, fn room ->
      candidate = %Placement{
        id: "candidate",
        plan_id: plan_id,
        term_id: session.term_id,
        session_id: session.id,
        session: session,
        room_id: room && room.id,
        room: room,
        day: day,
        slot: slot,
        duration_slots: session.duration_slots,
        week_mask: session.week_mask,
        locked: false
      }

      errors =
        NeuZeit.Constraints.Hard.check_placements([candidate | others], Config.grid!(term))
        |> Enum.filter(&("candidate" in &1.placement_ids))
        |> Enum.map(fn error ->
          related = Enum.filter(others, &(&1.id in error.placement_ids))

          detail =
            Enum.map_join(related, "; ", fn p ->
              weeks = Enum.filter(p.week_mask, &(&1 in session.week_mask)) |> Enum.join(", ")

              room = if p.room, do: p.room.name, else: "Online"

              "#{p.session.course_component.course.title}, #{p.session.teacher.name}, #{room}, #{weeks}"
            end)

          error
          |> Map.put(:related, detail)
          |> Map.put(
            :message,
            if(detail == "", do: error.message, else: "#{error.message}: #{detail}")
          )
        end)

      errors =
        errors ++
          NeuZeit.Planning.SharedResources.candidate_errors(external, term, session, candidate)

      %{room: room, errors: errors}
    end)
  end

  # Legality

  defp starts(session, days, slots, duration) do
    last_start = slots - duration + 1

    case session.slot_profile do
      nil ->
        for day <- 1..days, slot <- 1..max(last_start, 0)//1, do: {day, slot}

      profile ->
        profile.cells
        |> Enum.filter(&(&1.day <= days and &1.slot <= last_start))
        |> Enum.map(&{&1.day, &1.slot})
        |> Enum.uniq()
    end
  end

  # An empty allow-list means unrestricted, not unavailable.
  defp available?(availability, day, cells) do
    Enum.all?(cells, fn slot ->
      TeacherAvailabilityCell.unavailable_slots(availability, day, slot, 1) == []
    end)
  end

  # A teacher or cohort already busy in an overlapping week set blocks the cell.
  defp busy_index(placements, session) do
    cohort_ids = MapSet.new(session.cohorts, & &1.id)

    Enum.reduce(placements, %{}, fn placement, acc ->
      clashes? =
        placement.session.teacher_id == session.teacher_id or
          Enum.any?(placement.session.cohorts, &MapSet.member?(cohort_ids, &1.id))

      if clashes?, do: add_cells(acc, placement), else: acc
    end)
  end

  defp room_index(placements) do
    placements
    |> Enum.reject(&is_nil(&1.room_id))
    |> Enum.reduce(%{}, fn placement, acc ->
      add_cells(acc, placement, placement.room_id)
    end)
  end

  defp add_cells(acc, placement, key_prefix \\ nil) do
    duration = placement.duration_slots || 1

    Enum.reduce(placement.slot..(placement.slot + duration - 1), acc, fn slot, acc ->
      key = {key_prefix, placement.day, slot}
      Map.update(acc, key, [placement.week_mask], &[placement.week_mask | &1])
    end)
  end

  defp resource_busy?(busy, day, cells, week_mask) do
    Enum.any?(cells, fn slot ->
      busy
      |> Map.get({nil, day, slot}, [])
      |> Enum.any?(&WeekPattern.overlap?(&1, week_mask))
    end)
  end

  defp free_rooms(allowed_rooms, occupied, day, cells, week_mask) do
    Enum.filter(allowed_rooms, fn room_id ->
      is_nil(room_id) or
        Enum.all?(cells, fn slot ->
          occupied
          |> Map.get({room_id, day, slot}, [])
          |> Enum.all?(&(not WeekPattern.overlap?(&1, week_mask)))
        end)
    end)
  end

  defp other_placements(plan_id, session_id) do
    Repo.all(
      from p in Placement,
        where: p.plan_id == ^plan_id and p.session_id != ^session_id,
        preload: [session: :cohorts]
    )
  end

  # Explanations

  defp profile_reason(%{slot_profile: nil}), do: nil

  defp profile_reason(%{slot_profile: profile}),
    do: %{
      id: profile.id,
      name: profile.name,
      preset_key: profile.preset_key,
      starts: length(profile.cells)
    }

  defp availability_reason(%{teacher: teacher} = session) do
    case term_availability(session) do
      [] -> nil
      cells -> %{teacher_id: teacher.id, name: teacher.name, cells: length(cells)}
    end
  end

  defp term_availability(session) do
    Enum.filter(session.teacher.availability_cells || [], &(&1.term_id == session.term_id))
  end
end
