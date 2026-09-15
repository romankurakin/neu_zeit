defmodule NeuZeit.Constraints.Projection do
  alias NeuZeit.Scheduling.TermDates

  @moduledoc """
  Projects weekly template placements onto concrete dates and applies exceptions.
  """

  alias NeuZeit.Planning.Occurrence

  def project(term, placements, exceptions \\ []) do
    excluded = MapSet.new(term.excluded_dates || [])
    active_exceptions = Enum.filter(exceptions, &(&1.status == "active"))

    base =
      placements
      |> Enum.flat_map(&placement_occurrences(term, &1))
      |> apply_cancellations_and_moves(active_exceptions)

    additions = additions(active_exceptions)

    (base ++ additions)
    |> Enum.reject(fn occurrence ->
      occurrence.source == :template and
        (MapSet.member?(excluded, occurrence.date) or not TermDates.within?(term, occurrence.date))
    end)
    |> Enum.sort_by(&{Date.to_iso8601(&1.date), &1.slot, &1.room_id, &1.session_id})
  end

  @doc """
  Returns whether a session has a template occurrence on `date`.

  Excluded dates still count as template cells because a move may deliberately
  relocate a holiday occurrence. Dates outside the term never count.
  """
  def template_occurrence?(term, placements, session_id, date) do
    not Date.before?(date, term.starts_on) and not after_term?(term, date) and
      Enum.any?(placements, fn placement ->
        placement.session_id == session_id and
          Enum.any?(placement_occurrences(term, placement), &(&1.date == date))
      end)
  end

  defp placement_occurrences(term, placement) do
    Enum.map(placement.week_mask, fn week ->
      date = TermDates.date(term, week, placement.day)

      %Occurrence{
        session_id: placement.session_id,
        date: date,
        day: placement.day,
        slot: placement.slot,
        duration_slots: placement.duration_slots || 1,
        room_id: placement.room_id,
        teacher_id: session_teacher(placement),
        placement_id: placement.id,
        source: :template,
        cancelled?: false
      }
    end)
  end

  defp apply_cancellations_and_moves(occurrences, exceptions) do
    overrides =
      exceptions
      |> Enum.filter(&(&1.kind in ["cancel", "move", "substitute"]))
      |> Map.new(fn exception ->
        {{exception.session_id, exception.occurrence_date}, exception}
      end)

    occurrences
    |> Enum.flat_map(fn %Occurrence{} = occurrence ->
      case Map.get(overrides, {occurrence.session_id, occurrence.date}) do
        nil ->
          [occurrence]

        %{kind: "cancel"} ->
          []

        %{kind: "substitute"} = exception ->
          [
            %Occurrence{
              occurrence
              | teacher_id: exception.new_teacher_id,
                exception_id: exception.id,
                source: :substitute
            }
          ]

        %{kind: "move"} = exception ->
          date = exception.new_date || exception.occurrence_date

          [
            %Occurrence{
              occurrence
              | date: date,
                day: Date.day_of_week(date),
                slot: exception.new_slot,
                duration_slots: occurrence.duration_slots,
                room_id: exception.new_room_id,
                teacher_id: Map.get(exception, :new_teacher_id) || occurrence.teacher_id,
                exception_id: exception.id,
                source: :move
            }
          ]
      end
    end)
  end

  defp additions(exceptions) do
    exceptions
    |> Enum.filter(&(&1.kind == "add"))
    |> Enum.map(fn exception ->
      date = exception.new_date || exception.occurrence_date

      %Occurrence{
        session_id: exception.session_id,
        date: date,
        day: Date.day_of_week(date),
        slot: exception.new_slot,
        duration_slots: exception_duration(exception),
        room_id: exception.new_room_id,
        teacher_id: Map.get(exception, :new_teacher_id) || session_teacher(exception),
        exception_id: exception.id,
        source: :add,
        cancelled?: false
      }
    end)
  end

  defp session_teacher(%{session: %{teacher_id: id}}), do: id
  defp session_teacher(_record), do: nil

  defp after_term?(%{ends_on: %Date{} = ends_on}, date), do: Date.after?(date, ends_on)
  defp after_term?(_term, _date), do: false

  defp exception_duration(%{session: %{duration_slots: duration}}) when is_integer(duration),
    do: duration

  defp exception_duration(_exception), do: nil
end
