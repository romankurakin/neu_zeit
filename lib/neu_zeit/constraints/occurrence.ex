defmodule NeuZeit.Constraints.Occurrence do
  @moduledoc """
  Validates the concrete dated schedule produced by a term, its active plan,
  and its active exceptions.
  """

  import Ecto.Query, warn: false

  alias NeuZeit.Catalog.{DeliveryMode, Session, Teacher, TeacherAvailabilityCell}
  alias NeuZeit.Constraints.Projection
  alias NeuZeit.Repo

  def validate(term, placements, exceptions, opts \\ []) do
    dates = Keyword.get(opts, :dates, :all)

    occurrences =
      term
      |> Projection.project(placements, exceptions)
      |> filter_dates(dates)

    sessions_by_id =
      sessions_by_id(occurrences ++ Enum.map(placements, &%{session_id: &1.session_id}))

    errors =
      NeuZeit.Constraints.AutomaticWeeks.errors(term, placements, sessions_by_id) ++
        exception_date_errors(term, exceptions, sessions_by_id) ++
        orphaned_exception_errors(term, placements, exceptions, opts) ++
        room_eligibility_errors(occurrences, sessions_by_id) ++
        time_profile_errors(occurrences, sessions_by_id) ++
        teacher_availability_errors(term, occurrences, sessions_by_id) ++
        conflict_errors(occurrences, sessions_by_id) ++
        NeuZeit.Planning.SharedResources.errors(term, placements, exceptions)

    case Enum.uniq(errors) do
      [] -> :ok
      errors -> {:error, %{errors: errors}}
    end
  end

  def affected_dates(exceptions) do
    exceptions
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&[&1.occurrence_date, &1.new_date])
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp filter_dates(occurrences, :all), do: occurrences

  defp filter_dates(occurrences, dates),
    do: Enum.filter(occurrences, &MapSet.member?(dates, &1.date))

  defp exception_date_errors(term, exceptions, sessions_by_id) do
    days_count = length(NeuZeit.Config.grid!(term).days)
    slots_count = length(NeuZeit.Config.grid!(term).slots)
    excluded_dates = MapSet.new(term.excluded_dates || [])

    Enum.flat_map(exceptions, fn exception ->
      date_errors =
        [exception.occurrence_date, exception.new_date]
        |> Enum.reject(&is_nil/1)
        |> Enum.flat_map(fn date ->
          cond do
            Date.before?(date, term.starts_on) or Date.after?(date, term.ends_on) ->
              [
                exception_error(
                  "exception_outside_term",
                  "active exception date is outside the term",
                  exception,
                  date
                )
              ]

            Date.day_of_week(date) > days_count ->
              [
                exception_error(
                  "exception_outside_grid",
                  "active exception date is not a teaching day",
                  exception,
                  date
                )
              ]

            true ->
              []
          end
        end)

      excluded_target_errors =
        if exception.kind in ["move", "add", "substitute"] do
          target = exception.new_date || exception.occurrence_date

          if target && MapSet.member?(excluded_dates, target) do
            [
              exception_error(
                "exception_on_excluded_date",
                "active exception targets an excluded non-teaching date",
                exception,
                target
              )
            ]
          else
            []
          end
        else
          []
        end

      duration =
        case Map.get(sessions_by_id, exception.session_id) do
          %{duration_slots: duration} -> duration
          _ -> 1
        end

      slot_errors =
        if exception.kind in ["move", "add"] and
             (not is_integer(exception.new_slot) or exception.new_slot < 1 or
                exception.new_slot + duration - 1 > slots_count) do
          [
            exception_error(
              "exception_outside_grid",
              "active exception slot is outside the configured grid",
              exception,
              exception.new_date || exception.occurrence_date
            )
          ]
        else
          []
        end

      date_errors ++ excluded_target_errors ++ slot_errors
    end)
  end

  defp orphaned_exception_errors(term, placements, exceptions, opts) do
    if Keyword.get(opts, :require_origins, false) do
      exceptions
      |> Enum.filter(&(&1.status == "active" and &1.kind in ["move", "cancel", "substitute"]))
      |> Enum.reject(fn exception ->
        Projection.template_occurrence?(
          term,
          placements,
          exception.session_id,
          exception.occurrence_date
        )
      end)
      |> Enum.map(fn exception ->
        exception_error(
          "orphaned_exception",
          "exception does not match an occurrence in the projected plan",
          exception,
          exception.occurrence_date
        )
      end)
    else
      []
    end
  end

  defp room_eligibility_errors(occurrences, sessions_by_id) do
    occurrences
    |> Enum.filter(&(&1.source in [:move, :add]))
    |> Enum.flat_map(fn occurrence ->
      case Map.get(sessions_by_id, occurrence.session_id) do
        nil ->
          []

        session ->
          cond do
            DeliveryMode.room_valid?(
              occurrence.delivery_mode,
              occurrence.room_id,
              session.course_component
            ) ->
              []

            occurrence.delivery_mode == :online ->
              [
                occurrence_error(
                  "delivery_room_mismatch",
                  "online sessions do not use a room",
                  occurrence
                )
              ]

            true ->
              [
                occurrence_error(
                  "room_not_allowed",
                  "room is not allowed for the exception session component",
                  occurrence
                )
              ]
          end
      end
    end)
  end

  defp time_profile_errors(occurrences, sessions_by_id) do
    occurrences
    |> Enum.filter(&(&1.source in [:move, :add]))
    |> Enum.flat_map(fn occurrence ->
      case Map.get(sessions_by_id, occurrence.session_id) do
        %{slot_profile_id: nil} ->
          []

        %{slot_profile: %{cells: cells}} ->
          if Enum.any?(cells, &(&1.day == occurrence.day and &1.slot == occurrence.slot)) do
            []
          else
            [
              occurrence_error(
                "time_not_allowed",
                "exception start is not allowed by the session slot profile",
                occurrence
              )
            ]
          end

        _ ->
          []
      end
    end)
  end

  defp teacher_availability_errors(term, occurrences, sessions_by_id) do
    ids = occurrences |> Enum.map(& &1.teacher_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    teachers =
      Repo.all(from t in Teacher, where: t.id in ^ids, preload: [:availability_cells])
      |> Map.new(&{&1.id, &1})

    Enum.flat_map(occurrences, fn occurrence ->
      session = Map.get(sessions_by_id, occurrence.session_id)

      teacher =
        if occurrence.teacher_id,
          do: teachers[occurrence.teacher_id],
          else: session && session.teacher

      case teacher do
        %{availability_cells: cells} ->
          term_cells = Enum.filter(cells, &(&1.term_id == term.id))

          unavailable_slots =
            TeacherAvailabilityCell.unavailable_slots(
              term_cells,
              occurrence.day,
              occurrence.slot,
              occurrence_duration(occurrence, sessions_by_id)
            )

          if unavailable_slots == [] do
            []
          else
            [
              occurrence_error(
                "teacher_unavailable",
                "teacher is unavailable for occupied slots #{Enum.join(unavailable_slots, ",")}",
                occurrence
              )
            ]
          end

        _ ->
          []
      end
    end)
  end

  defp conflict_errors(occurrences, sessions_by_id) do
    occurrences
    |> Enum.group_by(& &1.date)
    |> Enum.flat_map(fn {_date, date_occurrences} ->
      date_occurrences
      |> pairs()
      |> Enum.flat_map(fn {left, right} ->
        if overlapping_occurrences?(left, right, sessions_by_id) do
          occurrence_conflicts(left, right, sessions_by_id)
        else
          []
        end
      end)
    end)
  end

  defp sessions_by_id(occurrences) do
    session_ids = occurrences |> Enum.map(& &1.session_id) |> Enum.uniq()

    Repo.all(
      from s in Session,
        where: s.id in ^session_ids,
        preload: [
          :cohorts,
          teacher: [:availability_cells],
          slot_profile: [:cells],
          course_component: [:allowed_rooms]
        ]
    )
    |> Map.new(&{&1.id, &1})
  end

  defp occurrence_conflicts(left, right, sessions_by_id) do
    left_session = Map.get(sessions_by_id, left.session_id)
    right_session = Map.get(sessions_by_id, right.session_id)

    room_conflict(left, right) ++
      resource_conflicts(left_session, right_session, left, right)
  end

  defp room_conflict(left, right) do
    if not is_nil(left.room_id) and left.room_id == right.room_id do
      [
        pair_error(
          "room_conflict",
          "room is already occupied at the exception target",
          left,
          right
        )
      ]
    else
      []
    end
  end

  defp resource_conflicts(nil, _right_session, _left, _right), do: []
  defp resource_conflicts(_left_session, nil, _left, _right), do: []

  defp resource_conflicts(left_session, right_session, left, right) do
    teacher =
      if (right.teacher_id || right_session.teacher_id) ==
           (left.teacher_id || left_session.teacher_id) do
        [
          pair_error(
            "teacher_conflict",
            "teacher is already teaching at the exception target",
            left,
            right
          )
        ]
      else
        []
      end

    left_cohorts = MapSet.new(left_session.cohorts, & &1.id)
    right_cohorts = MapSet.new(right_session.cohorts, & &1.id)

    cohort =
      if MapSet.disjoint?(left_cohorts, right_cohorts) do
        []
      else
        [
          pair_error(
            "cohort_conflict",
            "cohort is already attending another session at the exception target",
            left,
            right
          )
        ]
      end

    teacher ++ cohort
  end

  defp overlapping_occurrences?(left, right, sessions_by_id) do
    left_duration = occurrence_duration(left, sessions_by_id)
    right_duration = occurrence_duration(right, sessions_by_id)

    left.slot < right.slot + right_duration and right.slot < left.slot + left_duration
  end

  defp occurrence_duration(%{duration_slots: duration}, _sessions_by_id)
       when is_integer(duration),
       do: duration

  defp occurrence_duration(occurrence, sessions_by_id) do
    case Map.get(sessions_by_id, occurrence.session_id) do
      %{duration_slots: duration} when is_integer(duration) -> duration
      _ -> 1
    end
  end

  defp pair_error(type, message, left, right) do
    %{
      type: type,
      message: message,
      session_ids: Enum.uniq([left.session_id, right.session_id]),
      exception_ids:
        [left.exception_id, right.exception_id] |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      occurrence_dates: [Date.to_iso8601(left.date)]
    }
  end

  defp occurrence_error(type, message, occurrence) do
    %{
      type: type,
      message: message,
      session_ids: [occurrence.session_id],
      exception_ids: [occurrence.exception_id] |> Enum.reject(&is_nil/1),
      occurrence_dates: [Date.to_iso8601(occurrence.date)]
    }
  end

  defp exception_error(type, message, exception, date) do
    %{
      type: type,
      message: message,
      session_ids: [exception.session_id],
      exception_ids: [exception.id] |> Enum.reject(&is_nil/1),
      occurrence_dates: [Date.to_iso8601(date)]
    }
  end

  defp pairs([]), do: []
  defp pairs([_one]), do: []
  defp pairs([head | tail]), do: Enum.map(tail, &{head, &1}) ++ pairs(tail)
end
