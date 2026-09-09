defmodule NeuZeit.Planning.SharedResources do
  @moduledoc "Published bookings shared by overlapping terms, compared on actual dates."
  import Ecto.Query
  alias NeuZeit.{Catalog, Repo}
  alias NeuZeit.Catalog.{Term, Session}
  alias NeuZeit.Constraints.Projection
  alias NeuZeit.Planning.{Plan, ScheduleException}

  @doc "Serialize schedule writes before taking term/plan locks. Held only for the transaction."
  def lock! do
    Repo.query!("SELECT pg_advisory_xact_lock(72849, 1)")
    :ok
  end

  def external_index(term) do
    plans =
      Repo.all(
        from p in Plan,
          join: t in Term,
          on: t.id == p.term_id,
          where:
            p.status == "active" and p.term_id != ^term.id and
              t.starts_on <= ^term.ends_on and t.ends_on >= ^term.starts_on,
          preload: [:term, placements: :room]
      )

    ids = Enum.map(plans, & &1.term_id)

    if ids == [] do
      %{}
    else
      sessions =
        Repo.all(
          from s in Session,
            where: s.term_id in ^ids,
            preload: [:cohorts, :teacher, course_component: :course]
        )
        |> Map.new(&{&1.id, &1})

      exceptions =
        Repo.all(
          from e in ScheduleException,
            where: e.term_id in ^ids and e.status == "active",
            preload: [:session]
        )
        |> Enum.group_by(& &1.term_id)

      rooms = Catalog.list_rooms() |> Map.new(&{&1.id, &1.name})

      for plan <- plans,
          occurrence <-
            Projection.project(plan.term, plan.placements, Map.get(exceptions, plan.term_id, [])),
          Date.compare(occurrence.date, term.starts_on) != :lt,
          Date.compare(occurrence.date, term.ends_on) != :gt,
          session = Map.fetch!(sessions, occurrence.session_id),
          key <- keys(occurrence, session),
          reduce: %{} do
        index ->
          booking = %{
            term_id: plan.term_id,
            term_name: plan.term.name,
            plan_id: plan.id,
            session_id: session.id,
            date: occurrence.date,
            slot: occurrence.slot,
            placement_id: occurrence.placement_id,
            exception_id: occurrence.exception_id,
            course: session.course_component.course.code,
            teacher: session.teacher.name,
            room: Map.get(rooms, occurrence.room_id, occurrence.room_id),
            cohorts: Enum.map_join(session.cohorts, ", ", & &1.name)
          }

          Map.update(index, key, [booking], &[booking | &1])
      end
    end
  end

  def errors(term, placements, exceptions \\ []) do
    index = external_index(term)

    if map_size(index) == 0 do
      []
    else
      sessions = Catalog.list_sessions(term.id) |> Map.new(&{&1.id, &1})
      exceptions = Repo.preload(exceptions, :session)

      Projection.project(term, placements, exceptions)
      |> Enum.flat_map(fn occurrence ->
        case sessions[occurrence.session_id] do
          nil -> []
          session -> occurrence_errors(index, term, session, occurrence)
        end
      end)
      |> Enum.uniq()
    end
  end

  def validate(term, placements, exceptions \\ []) do
    case errors(term, placements, exceptions) do
      [] -> :ok
      errors -> {:error, %{errors: errors}}
    end
  end

  def candidate_errors(index, term, session, placement) do
    Projection.project(term, [placement])
    |> Enum.flat_map(&occurrence_errors(index, term, session, &1))
    |> Enum.uniq()
  end

  def blocked?(index, _term, _session, _placement) when map_size(index) == 0, do: false

  def blocked?(index, term, session, placement) do
    Enum.any?(Projection.project(term, [placement]), fn occurrence ->
      Enum.any?(keys(occurrence, session), &Map.has_key?(index, &1))
    end)
  end

  defp keys(occurrence, session) do
    resources =
      [{"room", occurrence.room_id}, {"teacher", session.teacher_id}] ++
        Enum.map(session.cohorts, &{"cohort", &1.id})

    for slot <-
          occurrence.slot..(occurrence.slot +
                              (occurrence.duration_slots || session.duration_slots) - 1),
        {kind, id} <- resources,
        do: {occurrence.date, slot, kind, id}
  end

  defp occurrence_errors(index, term, session, occurrence) do
    matches =
      for {date, _slot, kind, id} = key <- keys(occurrence, session),
          booking <- Map.get(index, key, []),
          do: {date, kind, id, booking}

    matches
    |> Enum.uniq()
    |> Enum.map(fn {date, kind, id, booking} ->
      %{
        type: "external_#{kind}_conflict",
        date: date,
        resource_id: id,
        resource_name:
          case kind do
            "teacher" -> session.teacher.name
            "room" -> booking.room
            "cohort" -> Enum.find(session.cohorts, &(&1.id == id)).name
          end,
        term_name: term.name,
        other_term_name: booking.term_name,
        other_course: booking.course,
        other_teacher: booking.teacher,
        other_room: booking.room,
        conflict_slot: booking.slot,
        session_id: session.id,
        term_id: term.id,
        other_term_id: booking.term_id,
        other_plan_id: booking.plan_id,
        other_session_id: booking.session_id,
        placement_ids: Enum.reject([occurrence.placement_id], &is_nil/1),
        message:
          "#{term.name} / #{booking.term_name}: #{kind} conflict on #{date}; #{booking.course}, #{booking.teacher}, #{booking.room}, #{booking.cohorts}; slot #{booking.slot}"
      }
    end)
  end
end
