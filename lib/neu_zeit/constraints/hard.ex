defmodule NeuZeit.Constraints.Hard do
  @moduledoc """
  Week-set-aware hard timetable checks.
  """

  alias NeuZeit.Catalog.{TeacherAvailabilityCell, WeekPattern}
  alias NeuZeit.Config

  def check_placements(placements, grid \\ Config.grid!()) do
    []
    |> Kernel.++(grid_errors(placements, grid))
    |> Kernel.++(week_mask_errors(placements))
    |> Kernel.++(duration_errors(placements))
    |> Kernel.++(room_eligibility_errors(placements))
    |> Kernel.++(time_profile_errors(placements))
    |> Kernel.++(teacher_availability_errors(placements))
    |> Kernel.++(one_placement_errors(placements))
    |> Kernel.++(pairwise_errors(placements))
  end

  def validate_placements(placements, grid \\ Config.grid!()) do
    case check_placements(placements, grid) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  def solver_rules(session_specs, room_specs) do
    %{
      room_groups:
        room_specs
        |> Enum.map(fn room ->
          session_ids =
            session_specs
            |> Enum.filter(&(room.id in &1.allowed_rooms))
            |> Enum.map(& &1.id)

          %{room_id: room.id, session_ids: session_ids}
        end)
        |> Enum.filter(&(length(&1.session_ids) > 1)),
      exclusive_groups:
        (teacher_groups(session_specs) ++ cohort_groups(session_specs))
        |> Enum.filter(&(length(&1.session_ids) > 1))
        |> Enum.uniq()
    }
  end

  defp grid_errors(placements, grid) do
    days_count = length(grid.days)
    slots_per_day = length(grid.slots)

    Enum.flat_map(placements, fn placement ->
      cond do
        placement.day < 1 or placement.day > days_count ->
          [error("grid_bounds", [placement.id], "day is outside the configured grid")]

        placement.slot < 1 or placement.slot + duration_slots(placement) - 1 > slots_per_day ->
          [
            error(
              "grid_bounds",
              [placement.id],
              "session duration extends outside the configured grid"
            )
          ]

        true ->
          []
      end
    end)
  end

  defp teacher_groups(session_specs) do
    session_specs
    |> Enum.group_by(& &1.teacher, & &1.id)
    |> Enum.sort_by(fn {teacher_id, _session_ids} -> teacher_id end)
    |> Enum.map(fn {_teacher_id, session_ids} -> %{session_ids: Enum.sort(session_ids)} end)
  end

  defp cohort_groups(session_specs) do
    session_specs
    |> Enum.flat_map(fn session -> Enum.map(session.cohorts, &{&1, session.id}) end)
    |> Enum.group_by(fn {cohort_id, _session_id} -> cohort_id end, fn {_cohort_id, session_id} ->
      session_id
    end)
    |> Enum.sort_by(fn {cohort_id, _session_ids} -> cohort_id end)
    |> Enum.map(fn {_cohort_id, session_ids} -> %{session_ids: Enum.sort(session_ids)} end)
  end

  defp week_mask_errors(placements) do
    Enum.flat_map(placements, fn placement ->
      session = placement.session

      valid =
        session &&
          if(Map.get(session, :automatic_weeks, false),
            do:
              length(placement.week_mask || []) == 1 &&
                Enum.all?(placement.week_mask, &(&1 in session.week_mask)),
            else: placement.week_mask == session.week_mask
          )

      if session && not valid do
        [
          error(
            "week_mask_mismatch",
            [placement.id],
            "placement week_mask must match session week_mask"
          )
        ]
      else
        []
      end
    end)
  end

  defp duration_errors(placements) do
    Enum.flat_map(placements, fn placement ->
      session = placement.session

      if session && placement.duration_slots != session.duration_slots do
        [
          error(
            "duration_mismatch",
            [placement.id],
            "placement duration_slots must match session duration_slots"
          )
        ]
      else
        []
      end
    end)
  end

  defp room_eligibility_errors(placements) do
    Enum.flat_map(placements, fn placement ->
      allowed_ids =
        placement.session.course_component.allowed_rooms
        |> Enum.map(& &1.id)
        |> MapSet.new()

      if MapSet.member?(allowed_ids, placement.room_id) do
        []
      else
        [error("room_not_allowed", [placement.id], "room is not allowed for this component")]
      end
    end)
  end

  defp time_profile_errors(placements) do
    Enum.flat_map(placements, fn placement ->
      case placement.session do
        %{slot_profile_id: nil} ->
          []

        %{slot_profile: %{cells: cells}} ->
          if Enum.any?(cells, &(&1.day == placement.day and &1.slot == placement.slot)) do
            []
          else
            [
              error(
                "time_not_allowed",
                [placement.id],
                "placement start is not allowed by the session slot profile"
              )
            ]
          end

        _session_without_loaded_profile ->
          []
      end
    end)
  end

  defp teacher_availability_errors(placements) do
    Enum.flat_map(placements, fn placement ->
      case placement.session do
        %{teacher: %{availability_cells: cells}} when is_list(cells) ->
          term_cells = Enum.filter(cells, &(&1.term_id == placement.term_id))

          unavailable_slots =
            TeacherAvailabilityCell.unavailable_slots(
              term_cells,
              placement.day,
              placement.slot,
              duration_slots(placement)
            )

          if unavailable_slots == [] do
            []
          else
            [
              error(
                "teacher_unavailable",
                [placement.id],
                "teacher is unavailable for occupied slots #{Enum.join(unavailable_slots, ",")}"
              )
            ]
          end

        _session_without_loaded_availability ->
          []
      end
    end)
  end

  defp one_placement_errors(placements) do
    placements
    |> Enum.group_by(& &1.session_id)
    |> Enum.flat_map(fn
      {_session_id, [_one]} ->
        []

      {_session_id, many} ->
        [error("duplicate_session", Enum.map(many, & &1.id), "session has multiple placements")]
    end)
  end

  defp pairwise_errors(placements) do
    placements
    |> pairs()
    |> Enum.flat_map(fn {left, right} ->
      if overlapping_cells?(left, right) && WeekPattern.overlap?(left.week_mask, right.week_mask) do
        room_conflict(left, right) ++
          teacher_conflict(left, right) ++ cohort_conflict(left, right)
      else
        []
      end
    end)
  end

  defp room_conflict(left, right) do
    if left.room_id == right.room_id do
      [
        error(
          "room_conflict",
          ids(left, right),
          "room is already occupied on an overlapping week set"
        )
      ]
    else
      []
    end
  end

  defp teacher_conflict(left, right) do
    if left.session.teacher_id == right.session.teacher_id do
      [
        error(
          "teacher_conflict",
          ids(left, right),
          "teacher is already teaching on an overlapping week set"
        )
      ]
    else
      []
    end
  end

  defp cohort_conflict(left, right) do
    left_cohorts = left.session.cohorts |> Enum.map(& &1.id) |> MapSet.new()
    right_cohorts = right.session.cohorts |> Enum.map(& &1.id) |> MapSet.new()

    if MapSet.disjoint?(left_cohorts, right_cohorts) do
      []
    else
      [error("cohort_conflict", ids(left, right), "cohort is already attending another session")]
    end
  end

  defp overlapping_cells?(left, right) do
    left.day == right.day and
      left.slot < right.slot + duration_slots(right) and
      right.slot < left.slot + duration_slots(left)
  end

  defp duration_slots(%{duration_slots: duration}) when is_integer(duration), do: duration

  defp duration_slots(%{session: %{duration_slots: duration}}) when is_integer(duration),
    do: duration

  defp duration_slots(_placement), do: 1
  defp ids(left, right), do: [left.id, right.id]

  defp pairs([]), do: []
  defp pairs([_one]), do: []

  defp pairs([head | tail]) do
    Enum.map(tail, &{head, &1}) ++ pairs(tail)
  end

  defp error(type, placement_ids, message) do
    %{type: type, placement_ids: placement_ids, message: message}
  end
end
