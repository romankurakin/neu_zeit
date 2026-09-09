defmodule NeuZeit.Planning.Quality do
  @moduledoc """
  Computes quality metrics per teaching week for groups and teachers.

  Metrics include gaps, active days, evening and Saturday sessions, building
  changes, sequence spacing and breaks in teaching weeks. Results are summarized
  after weekly calculation so differences between weeks remain visible.
  """

  alias NeuZeit.Config
  alias NeuZeit.Planning

  @doc """
  The full report for a plan.

  Returns per-cohort and per-teacher rows, plus sequence and room observations.
  """
  def report(plan_id, opts \\ []) do
    grid = Keyword.get(opts, :grid, Config.grid!())
    placements = Planning.list_placements(plan_id)

    %{
      cohorts: subject_rows(placements, grid, &cohort_keys/1),
      teachers: subject_rows(placements, grid, &teacher_keys/1),
      sequences: sequences(placements),
      rooms: rooms(placements),
      evening_slot: evening_slot(grid),
      saturday: length(grid.days)
    }
  end

  # Per-subject measurement

  defp cohort_keys(placement),
    do: Enum.map(placement.session.cohorts, &{&1.id, &1.name})

  defp teacher_keys(placement),
    do: [{placement.session.teacher_id, placement.session.teacher.name}]

  defp subject_rows(placements, grid, key_fun) do
    placements
    |> Enum.flat_map(fn placement ->
      Enum.map(key_fun.(placement), &{&1, placement})
    end)
    |> Enum.group_by(fn {key, _placement} -> key end, fn {_key, placement} -> placement end)
    |> Enum.map(fn {{id, name}, owned} -> measure(id, name, owned, grid) end)
    |> Enum.sort_by(& &1.name)
  end

  defp measure(id, name, placements, grid) do
    weeks = placements |> Enum.flat_map(& &1.week_mask) |> Enum.uniq() |> Enum.sort()
    per_week = Enum.map(weeks, &week_shape(placements, &1, grid))

    %{
      id: id,
      name: name,
      weeks: weeks,
      # Count empty time slots between sessions.
      gaps: Enum.sum(Enum.map(per_week, & &1.gaps)),
      worst_week_gaps: per_week |> Enum.map(& &1.gaps) |> Enum.max(fn -> 0 end),
      # Count days with exactly one session.
      active_days: per_week |> Enum.map(& &1.active_days) |> Enum.max(fn -> 0 end),
      isolated_days: Enum.sum(Enum.map(per_week, & &1.isolated_days)),
      # Find days with sessions in the first and last slots and a gap between them.
      long_days: Enum.sum(Enum.map(per_week, & &1.long_days)),
      # Count evening and Saturday sessions.
      evening:
        count_cells(placements, fn p, slot ->
          slot >= evening_slot(grid) and p.day < length(grid.days)
        end),
      saturday: count_cells(placements, fn p, _slot -> p.day == length(grid.days) end),
      # Count building changes within each teaching day.
      building_transitions: Enum.sum(Enum.map(per_week, & &1.building_transitions)),
      # Find breaks in the session week sets.
      first_week: List.first(weeks),
      last_week: List.last(weeks),
      calendar_gap: largest_internal_gap(weeks)
    }
  end

  defp week_shape(placements, week, grid) do
    in_week = Enum.filter(placements, &(week in &1.week_mask))

    by_day =
      in_week
      |> Enum.group_by(& &1.day)
      |> Enum.map(fn {day, day_placements} -> {day, day_shape(day_placements)} end)

    %{
      gaps: by_day |> Enum.map(fn {_day, shape} -> shape.gaps end) |> Enum.sum(),
      active_days: length(by_day),
      isolated_days: Enum.count(by_day, fn {_day, shape} -> shape.classes == 1 end),
      long_days:
        Enum.count(by_day, fn {_day, shape} ->
          shape.span >= length(grid.slots) - 1 and shape.gaps > 0
        end),
      building_transitions:
        by_day |> Enum.map(fn {_day, shape} -> shape.building_transitions end) |> Enum.sum()
    }
  end

  defp day_shape(placements) do
    occupied =
      placements
      |> Enum.flat_map(&occupied_slots/1)
      |> Enum.uniq()
      |> Enum.sort()

    first = List.first(occupied)
    last = List.last(occupied)

    %{
      classes: length(placements),
      span: if(first, do: last - first + 1, else: 0),
      # Empty slots between the first and last class of the day.
      gaps: if(first, do: last - first + 1 - length(occupied), else: 0),
      building_transitions: building_transitions(placements)
    }
  end

  defp occupied_slots(placement),
    do: Enum.to_list(placement.slot..(placement.slot + (placement.duration_slots || 1) - 1))

  defp building_transitions(placements) do
    placements
    |> Enum.sort_by(& &1.slot)
    |> Enum.map(& &1.room.building_id)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.count(fn [a, b] -> a != b end)
  end

  defp count_cells(placements, predicate) do
    Enum.reduce(placements, 0, fn placement, acc ->
      matching = Enum.count(occupied_slots(placement), &predicate.(placement, &1))
      acc + matching * length(placement.week_mask)
    end)
  end

  # The evening is the last third of the teaching day.
  defp evening_slot(grid), do: max(length(grid.slots) - 1, 1)

  # Flag internal breaks of four or more weeks for review of the session week sets.
  defp largest_internal_gap([]), do: 0

  defp largest_internal_gap(weeks) do
    weeks
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> b - a - 1 end)
    |> Enum.max(fn -> 0 end)
  end

  # Sequences

  @doc false
  def sequences(placements) do
    placements
    |> Enum.reject(&is_nil(&1.session.sequence_group))
    |> Enum.group_by(& &1.session.sequence_group)
    |> Enum.filter(fn {_group, members} -> length(members) > 1 end)
    |> Enum.map(fn {group, members} ->
      %{
        group: group,
        placements: length(members),
        adjacent: adjacent?(members),
        days: members |> Enum.map(& &1.day) |> Enum.uniq() |> Enum.sort()
      }
    end)
    |> Enum.sort_by(& &1.group)
  end

  # Adjacent means same day, and the blocks touch without a slot between them.
  defp adjacent?(members) do
    case Enum.map(members, & &1.day) |> Enum.uniq() do
      [_single_day] ->
        members
        |> Enum.sort_by(& &1.slot)
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.all?(fn [a, b] -> a.slot + (a.duration_slots || 1) == b.slot end)

      _several_days ->
        false
    end
  end

  # Rooms

  @doc false
  def rooms(placements) do
    placements
    |> Enum.group_by(& &1.room_id)
    |> Enum.map(fn {_room_id, used} ->
      room = hd(used).room

      %{
        id: room.id,
        name: room.name,
        first_week: used |> Enum.flat_map(& &1.week_mask) |> Enum.min(),
        placements: length(used),
        occupied_cells:
          Enum.sum(Enum.map(used, &(length(occupied_slots(&1)) * length(&1.week_mask))))
      }
    end)
    |> Enum.sort_by(&(-&1.occupied_cells))
  end

  @doc """
  Summarizes report metrics for the quality cards.
  """
  def verdicts(report) do
    subjects = report.cohorts ++ report.teachers

    %{
      gaps: sum(subjects, :gaps),
      isolated_days: sum(subjects, :isolated_days),
      long_days: sum(subjects, :long_days),
      evening: sum(subjects, :evening),
      saturday: sum(subjects, :saturday),
      building_transitions: sum(subjects, :building_transitions),
      sequences_split: Enum.count(report.sequences, &(not &1.adjacent)),
      calendar_gaps: Enum.count(subjects, &(&1.calendar_gap >= 4))
    }
  end

  defp sum(rows, key), do: rows |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sum()
end
