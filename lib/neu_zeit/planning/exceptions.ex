defmodule NeuZeit.Planning.Exceptions do
  @moduledoc false
  alias NeuZeit.Planning.WriteSupport
  import Ecto.Query, warn: false
  alias NeuZeit.Catalog.Session
  alias NeuZeit.Catalog.Term
  alias NeuZeit.Constraints.Occurrence
  alias NeuZeit.Constraints.Projection
  alias NeuZeit.Planning.Placement
  alias NeuZeit.Planning.ScheduleException
  alias NeuZeit.Repo

  def list_schedule_exceptions do
    Repo.all(from e in ScheduleException, order_by: [asc: e.term_id, asc: e.occurrence_date])
  end

  @doc """
  A term's one-off changes, newest occurrence first.
  """
  def list_schedule_exceptions(term_id) do
    Repo.all(
      from e in ScheduleException,
        where: e.term_id == ^term_id,
        order_by: [desc: e.occurrence_date, asc: e.inserted_at],
        preload: [
          :new_room,
          :new_teacher,
          session: [
            :cohorts,
            :teacher,
            course_component: [course: :translations, teaching_type: :translations]
          ]
        ]
    )
  end

  def get_schedule_exception!(id, term_id) do
    record = get_schedule_exception!(id)
    if record.term_id != term_id, do: raise(Ecto.NoResultsError, queryable: ScheduleException)
    record
  end

  def get_schedule_exception!(id), do: Repo.get!(ScheduleException, id)

  def change_schedule_exception(%ScheduleException{} = exception, attrs \\ %{}),
    do: ScheduleException.changeset(exception, attrs)

  def create_schedule_exception(attrs) do
    WriteSupport.transaction_result(fn ->
      with {:ok, attrs} <- hydrate_exception_attrs(attrs),
           {:ok, term} <- lock_term(WriteSupport.attr(attrs, :term_id)),
           changeset = ScheduleException.changeset(%ScheduleException{}, attrs),
           :ok <- validate_exception_change(term, changeset, nil),
           {:ok, exception} <- Repo.insert(changeset) do
        {:ok, exception}
      end
    end)
  end

  def update_schedule_exception(%ScheduleException{} = exception, attrs) do
    WriteSupport.transaction_result(fn ->
      with {:ok, term} <- lock_term(exception.term_id),
           {:ok, current} <- lock_schedule_exception(exception.id),
           changeset = ScheduleException.update_changeset(current, attrs),
           :ok <- validate_exception_change(term, changeset, current),
           {:ok, updated} <- Repo.update(changeset) do
        {:ok, updated}
      end
    end)
  end

  def delete_schedule_exception(%ScheduleException{} = exception) do
    WriteSupport.transaction_result(fn ->
      with {:ok, term} <- lock_term(exception.term_id),
           {:ok, current} <- lock_schedule_exception(exception.id),
           :ok <- validate_exception_removal(term, current),
           {:ok, deleted} <- Repo.delete(current) do
        {:ok, deleted}
      end
    end)
  end

  defp hydrate_exception_attrs(attrs) do
    with {:ok, session_id} <-
           WriteSupport.require_id(
             WriteSupport.attr(attrs, :session_id),
             %ScheduleException{},
             :session_id
           ),
         %Session{} = session <- Repo.get(Session, session_id) do
      if WriteSupport.attr(attrs, :term_id) not in [nil, session.term_id],
        do:
          WriteSupport.error_result(%ScheduleException{}, :term_id, "must match the session term"),
        else: {:ok, attrs |> WriteSupport.stringify_keys() |> Map.put("term_id", session.term_id)}
    else
      {:error, _reason} = error -> error
      nil -> WriteSupport.error_result(%ScheduleException{}, :session_id, "does not exist")
    end
  end

  defp validate_exception_change(term, changeset, previous) do
    candidate = Ecto.Changeset.apply_changes(changeset)

    if changeset.valid? and exception_dates_valid?(term, candidate) do
      placements = active_placements(term.id)
      existing = active_exceptions(term.id, previous && previous.id)

      resulting =
        if candidate.status == "active", do: [candidate | existing], else: existing

      with :ok <- validate_candidate_origin(changeset, term, placements, candidate),
           :ok <-
             Occurrence.validate(
               term,
               placements,
               resulting,
               dates: Occurrence.affected_dates([previous, candidate])
             ) do
        :ok
      end
    else
      :ok
    end
  end

  defp validate_exception_removal(term, exception) do
    placements = active_placements(term.id)
    resulting = active_exceptions(term.id, exception.id)

    Occurrence.validate(
      term,
      placements,
      resulting,
      dates: Occurrence.affected_dates([exception])
    )
  end

  defp validate_candidate_origin(changeset, term, placements, candidate) do
    excluded_dates = MapSet.new(term.excluded_dates || [])

    cond do
      candidate.status != "active" ->
        :ok

      candidate.kind in ["move", "cancel", "substitute"] and
          not Projection.template_occurrence?(
            term,
            placements,
            candidate.session_id,
            candidate.occurrence_date
          ) ->
        {:error,
         Ecto.Changeset.add_error(
           changeset,
           :occurrence_date,
           "does not match any scheduled occurrence"
         )}

      candidate.kind in ["cancel", "substitute"] and
          MapSet.member?(excluded_dates, candidate.occurrence_date) ->
        {:error,
         Ecto.Changeset.add_error(
           changeset,
           :occurrence_date,
           "is already removed from the schedule by an excluded date"
         )}

      true ->
        :ok
    end
  end

  defp active_placements(term_id) do
    Repo.all(
      from p in Placement,
        join: plan in assoc(p, :plan),
        where: plan.term_id == ^term_id and plan.status == "active"
    )
  end

  def active_exceptions(term_id, exclude_id) do
    query =
      from e in ScheduleException,
        where: e.term_id == ^term_id and e.status == "active"

    query = if exclude_id, do: from(e in query, where: e.id != ^exclude_id), else: query
    Repo.all(query)
  end

  defp exception_dates_valid?(term, exception) do
    days_count = length(NeuZeit.Config.grid!(term).days)
    slots_count = length(NeuZeit.Config.grid!(term).slots)

    duration_slots =
      case Repo.get(Session, exception.session_id) do
        %Session{duration_slots: duration} -> duration
        nil -> 1
      end

    valid_date? = fn
      nil ->
        true

      %Date{} = date ->
        not Date.before?(date, term.starts_on) and not Date.after?(date, term.ends_on) and
          Date.day_of_week(date) <= days_count

      _other ->
        false
    end

    valid_date?.(exception.occurrence_date) and valid_date?.(exception.new_date) and
      (is_nil(exception.new_slot) or
         (is_integer(exception.new_slot) and exception.new_slot > 0 and
            exception.new_slot + duration_slots - 1 <= slots_count))
  end

  defp lock_term(term_id) do
    case Repo.one(from t in Term, where: t.id == ^term_id, lock: "FOR UPDATE") do
      %Term{} = term -> {:ok, term}
      nil -> WriteSupport.error_result(%ScheduleException{}, :term_id, "does not exist")
    end
  end

  defp lock_schedule_exception(id) do
    case Repo.one(from e in ScheduleException, where: e.id == ^id, lock: "FOR UPDATE") do
      %ScheduleException{} = exception -> {:ok, exception}
      nil -> {:error, :not_found}
    end
  end
end
