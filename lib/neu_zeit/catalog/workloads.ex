defmodule NeuZeit.Catalog.Workloads do
  @moduledoc "Loads teaching requirements and applies proposed session changes transactionally."
  import Ecto.Changeset
  import Ecto.Query

  alias NeuZeit.Catalog.{Sessions, Term, Workload, WorkloadDistribution, WorkloadSnapshot}
  alias NeuZeit.Planning.{Placement, ScheduleException}
  alias NeuZeit.Repo

  def list(term_id) do
    sessions = Sessions.list_sessions(term_id) |> Enum.group_by(& &1.workload_id)

    placed_ids =
      Repo.all(
        from p in Placement, where: p.term_id == ^term_id, select: p.session_id, distinct: true
      )
      |> MapSet.new()

    history_ids =
      Repo.all(
        from e in ScheduleException,
          where: e.term_id == ^term_id,
          select: e.session_id,
          distinct: true
      )
      |> MapSet.new()

    Repo.all(
      from w in Workload,
        where: w.term_id == ^term_id,
        preload: [
          :cohorts,
          :teacher,
          :slot_profile,
          course_component: [teaching_type: :translations, course: :translations]
        ]
    )
    |> Enum.map(fn requirement ->
      requirement = %{requirement | cohort_ids: Enum.map(requirement.cohorts, & &1.id)}
      generated = Map.get(sessions, requirement.id, []) |> Enum.sort_by(& &1.id)
      ids = MapSet.new(generated, & &1.id)

      %WorkloadSnapshot{
        id: requirement.id,
        requirement: requirement,
        sessions: generated,
        placed_ids: MapSet.intersection(placed_ids, ids),
        history_ids: MapSet.intersection(history_ids, ids)
      }
    end)
    |> Enum.sort_by(
      &{&1.requirement.course_component.course.title, &1.requirement.course_component.kind, &1.id}
    )
  end

  def save(term_id, original, attrs) do
    case save_requirement(term_id, original, attrs) do
      {:ok, _requirement} -> {:ok, :saved}
      error -> error
    end
  end

  def save_requirement(term_id, original, attrs) do
    Repo.transaction(fn ->
      term = lock_term!(term_id)

      save_locked(term, original, attrs, index(list(term_id)))
    end)
  end

  defp save_locked(term, original, attrs, current) do
    term_id = term.id

    changeset =
      Workload.changeset((original && original.requirement) || Workload.new(term), term, attrs)

    workload =
      case apply_action(changeset, :insert) do
        {:ok, workload} -> workload
        {:error, error} -> Repo.rollback(error)
      end

    snapshot = current_snapshot!(current.rows, original)
    session_attrs = Workload.session_attributes(workload)

    duplicate_ids = Map.get(current.identities, identity(workload), [])

    if Enum.any?(duplicate_ids, &(&1 != (original && original.id))) do
      Repo.rollback(
        add_error(
          changeset,
          :course_component_id,
          "This teaching load already exists. Edit its hours."
        )
      )
    end

    proposal =
      WorkloadDistribution.propose(workload, term, snapshot,
        parity_changed?: Map.has_key?(changeset.changes, :remainder_parity)
      )

    protect_removals!(proposal, snapshot, changeset)
    requirement = unwrap!(Repo.insert_or_update(changeset), changeset)

    Enum.each(proposal.removed, &unwrap!(Sessions.delete_generated_session(&1), changeset))

    for {session, mask} <- proposal.retained do
      unwrap!(
        Sessions.update_generated_session(session, Map.put(session_attrs, :week_mask, mask)),
        changeset
      )
    end

    for mask <- proposal.new_masks do
      unwrap!(
        Sessions.create_generated_session(
          requirement.id,
          session_attrs |> Map.put(:term_id, term_id) |> Map.put(:week_mask, mask)
        ),
        changeset
      )
    end

    Repo.delete_all(
      from wc in NeuZeit.Catalog.WorkloadCohort,
        where: wc.workload_id == ^requirement.id
    )

    Repo.insert_all(
      NeuZeit.Catalog.WorkloadCohort,
      Enum.map(workload.cohort_ids, &%{workload_id: requirement.id, cohort_id: &1})
    )

    requirement
  end

  def prepare(term_id) do
    Repo.transaction(fn ->
      term = lock_term!(term_id)

      rows = list(term_id)
      current = index(rows)

      for row <- rows do
        case row.requirement |> Workload.changeset(term) |> apply_action(:insert) do
          {:ok, workload} ->
            unless WorkloadDistribution.synchronized?(workload, term, row.sessions) do
              save_locked(term, row, %{}, current)
            end

          {:error, error} ->
            Repo.rollback(error)
        end
      end

      :ready
    end)
  end

  def check(term_id) do
    term = Repo.get!(Term, term_id)

    if Enum.all?(list(term_id), fn row ->
         changeset = Workload.changeset(row.requirement, term)

         changeset.valid? &&
           WorkloadDistribution.synchronized?(apply_changes(changeset), term, row.sessions)
       end),
       do: :ok,
       else: {:error, {:conflict, "Teaching load and sessions differ. Run the scheduler again."}}
  end

  def delete(term_id, original) do
    Repo.transaction(fn ->
      lock_term!(term_id)
      snapshot = current_snapshot!(Map.new(list(term_id), &{&1.id, &1}), original)

      if MapSet.size(snapshot.placed_ids) > 0,
        do: Repo.rollback({:conflict, "Remove placements before deleting this teaching load."})

      for session <- snapshot.sessions do
        case Sessions.delete_generated_session(session) do
          {:ok, _} -> :ok
          {:error, error} -> Repo.rollback(error)
        end
      end

      Repo.delete!(snapshot.requirement)
      :deleted
    end)
  end

  def hours(%WorkloadSnapshot{} = row), do: row.requirement.contact_hours
  def series_count(%WorkloadSnapshot{} = row), do: length(row.sessions)

  def meeting_count(%WorkloadSnapshot{} = row),
    do: WorkloadDistribution.meeting_count(row.sessions)

  def planned_hours(%WorkloadSnapshot{requirement: %{term_id: id}} = row, %Term{id: id} = term),
    do: WorkloadDistribution.planned_hours(row.sessions, term)

  def planned_hours(%WorkloadSnapshot{}, %Term{}),
    do: raise(ArgumentError, "Planned hours require the workload's term")

  defdelegate duration_options(term), to: WorkloadDistribution

  defp lock_term!(term_id) do
    NeuZeit.Planning.SharedResources.lock!()
    Repo.one!(from t in Term, where: t.id == ^term_id, lock: "FOR UPDATE")
  end

  defp protect_removals!(_proposal, nil, _changeset), do: :ok

  defp protect_removals!(proposal, snapshot, changeset) do
    if Enum.any?(proposal.removed, &MapSet.member?(snapshot.placed_ids, &1.id)),
      do:
        Repo.rollback(
          add_error(changeset, :contact_hours, "Remove placements before reducing this workload.")
        )

    if Enum.any?(proposal.removed, &MapSet.member?(snapshot.history_ids, &1.id)),
      do:
        Repo.rollback(
          add_error(
            changeset,
            :contact_hours,
            "Changing this teaching load would delete session history. Keep the existing sessions."
          )
        )
  end

  defp index(rows) do
    %{
      rows: Map.new(rows, &{&1.id, &1}),
      identities: Enum.group_by(rows, &identity(&1.requirement), & &1.id)
    }
  end

  defp current_snapshot!(_rows, nil), do: nil

  defp current_snapshot!(rows, %WorkloadSnapshot{} = original) do
    current = Map.get(rows, original.id)

    if current && fingerprint(current) == fingerprint(original),
      do: current,
      else: Repo.rollback({:conflict, "The workload changed. Reload it before saving."})
  end

  defp fingerprint(row) do
    {requirement_key(row.requirement), Enum.map(row.sessions, &{&1.id, session_key(&1)}),
     row.placed_ids, row.history_ids}
  end

  defp requirement_key(requirement) do
    requirement
    |> Workload.session_attributes()
    |> normalize_attributes()
    |> Map.merge(Map.take(requirement, [:contact_hours, :rounding_mode, :remainder_parity]))
  end

  defp session_key(session) do
    session
    |> Workload.session_attributes()
    |> Map.put(:cohort_ids, Enum.map(session.cohorts, & &1.id))
    |> normalize_attributes()
  end

  defp identity(requirement),
    do:
      requirement
      |> Workload.session_attributes()
      |> Map.delete(:automatic_weeks)
      |> normalize_attributes()

  defp normalize_attributes(attrs),
    do: attrs |> Map.update!(:cohort_ids, &Enum.sort/1) |> Map.update!(:week_mask, &Enum.sort/1)

  defp unwrap!({:ok, result}, _changeset), do: result

  defp unwrap!({:error, %Ecto.Changeset{} = error}, changeset) do
    changeset =
      Enum.reduce(error.errors, changeset, fn {field, {message, opts}}, acc ->
        add_error(acc, field, message, opts)
      end)

    Repo.rollback(%{changeset | action: :insert})
  end

  defp unwrap!({:error, reason}, _changeset), do: Repo.rollback(reason)
end
