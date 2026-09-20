defmodule NeuZeit.Catalog.Sessions do
  @moduledoc false
  alias NeuZeit.Catalog.ScheduleValidation
  alias NeuZeit.Catalog.WriteSupport
  import Ecto.Query, warn: false
  alias Ecto.Multi
  alias NeuZeit.Catalog.Cohort
  alias NeuZeit.Catalog.CourseComponent
  alias NeuZeit.Catalog.Session
  alias NeuZeit.Catalog.SessionCohort
  alias NeuZeit.Catalog.Term
  alias NeuZeit.Planning.Placement
  alias NeuZeit.Planning.ScheduleException
  alias NeuZeit.Repo

  def list_sessions do
    Repo.all(
      from s in Session,
        order_by: [asc: s.term_id, asc: s.id],
        preload: [
          :term,
          :cohorts,
          teacher: [:availability_cells],
          slot_profile: [:cells],
          course_component: [:allowed_rooms, course: :translations, teaching_type: :translations]
        ]
    )
  end

  @doc """
  Lists sessions for one term with optional filters.

  Filters: `:course_id`, `:teacher_id`, `:cohort_id`, `:slot_profile_id`,
  `:without_profile` and `:unplaced_in_plan`. `list_sessions/0` covers all terms.
  """
  def list_sessions(term_id, filters \\ %{}, opts \\ []) do
    Session
    |> where([s], s.term_id == ^term_id)
    |> apply_session_filters(filters)
    |> order_by([s], asc: s.inserted_at, asc: s.id)
    |> preload([
      :cohorts,
      teacher: [:availability_cells],
      slot_profile: [:cells],
      course_component: [:allowed_rooms, course: :translations, teaching_type: :translations]
    ])
    |> session_page(opts)
    |> Repo.all()
  end

  def count_sessions(term_id, filters \\ %{}) do
    Session
    |> where([s], s.term_id == ^term_id)
    |> apply_session_filters(filters)
    |> Repo.aggregate(:count)
  end

  defp session_page(query, []), do: query

  defp session_page(query, opts) do
    size = Keyword.fetch!(opts, :per_page)
    page = max(Keyword.get(opts, :page, 1), 1)
    query |> limit(^size) |> offset(^((page - 1) * size))
  end

  defp apply_session_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {_key, value}, query when value in [nil, "", "all"] ->
        query

      {:course_id, course_id}, query ->
        join(query, :inner, [s], c in CourseComponent,
          as: :course_component,
          on: s.course_component_id == c.id
        )
        |> where([course_component: c], c.course_id == ^course_id)

      {:teacher_id, teacher_id}, query ->
        where(query, [s], s.teacher_id == ^teacher_id)

      {:slot_profile_id, profile_id}, query ->
        where(query, [s], s.slot_profile_id == ^profile_id)

      {:cohort_id, cohort_id}, query ->
        join(query, :inner, [s], sc in "session_cohorts",
          as: :session_cohort,
          on: sc.session_id == s.id
        )
        |> where([session_cohort: sc], sc.cohort_id == type(^cohort_id, Ecto.UUID))

      {:without_profile, true}, query ->
        where(query, [s], is_nil(s.slot_profile_id))

      # Select sessions that have no placement in the requested plan.
      {:unplaced_in_plan, plan_id}, query ->
        where(
          query,
          [s],
          not exists(
            from p in NeuZeit.Planning.Placement,
              where: p.session_id == parent_as(:session).id and p.plan_id == ^plan_id,
              select: 1
          )
        )
        |> from(as: :session)

      {_key, _value}, query ->
        query
    end)
  end

  def get_session!(id, term_id) do
    record = get_session!(id)
    if record.term_id != term_id, do: raise(Ecto.NoResultsError, queryable: Session)
    record
  end

  def get_session!(id) do
    Session
    |> Repo.get!(id)
    |> Repo.preload([
      :term,
      :cohorts,
      teacher: [:availability_cells],
      slot_profile: [:cells],
      course_component: [:allowed_rooms, course: :translations, teaching_type: :translations]
    ])
  end

  @doc false
  def create_generated_session(workload_id, attrs) do
    with {:ok, cohort_ids} <-
           WriteSupport.normalize_existing_ids(
             WriteSupport.attr(attrs, :cohort_ids, []),
             :cohort_ids,
             %Session{},
             Cohort
           ) do
      Multi.new()
      |> Multi.run(:shared_schedule_lock, fn _repo, _changes ->
        {:ok, NeuZeit.Planning.SharedResources.lock!()}
      end)
      |> Multi.run(:term_lock, fn repo, _changes ->
        case Ecto.UUID.cast(WriteSupport.attr(attrs, :term_id)) do
          {:ok, term_id} ->
            case repo.one(from t in Term, where: t.id == ^term_id, lock: "FOR UPDATE") do
              %Term{} = term ->
                {:ok, term}

              nil ->
                {:error, WriteSupport.error_changeset(%Session{}, :term_id, "does not exist")}
            end

          :error ->
            # Let the session changeset return the canonical blank/invalid error.
            {:ok, :invalid_term_id}
        end
      end)
      |> Multi.insert(:session, Session.changeset(%Session{workload_id: workload_id}, attrs))
      |> Multi.run(:cohorts, fn repo, %{session: session} ->
        replace_session_cohorts(repo, session.id, cohort_ids)
      end)
      |> Repo.transaction()
      |> WriteSupport.unwrap_multi(:session)
    end
  end

  @doc false
  def update_generated_session(%Session{} = session, attrs) do
    with {:ok, cohort_ids} <-
           WriteSupport.maybe_normalize_existing_ids(
             WriteSupport.attr(attrs, :cohort_ids),
             :cohort_ids,
             %Session{},
             Cohort
           ) do
      Multi.new()
      |> Multi.run(:shared_schedule_lock, fn _repo, _changes ->
        {:ok, NeuZeit.Planning.SharedResources.lock!()}
      end)
      # Session edits and exception mutations share the term lock because both
      # can change the published dated schedule.
      |> Multi.run(:term_lock, fn repo, _changes ->
        {:ok, repo.one!(from t in Term, where: t.id == ^session.term_id, lock: "FOR UPDATE")}
      end)
      |> Multi.update(:session, Session.update_changeset(session, attrs))
      |> WriteSupport.maybe_replace(:cohorts, cohort_ids, fn repo, %{session: session} ->
        replace_session_cohorts(repo, session.id, cohort_ids)
      end)
      |> Multi.run(:placements, fn repo, %{session: updated_session} ->
        ScheduleValidation.sync_and_revalidate_plans(
          repo,
          session,
          updated_session,
          not is_nil(cohort_ids)
        )
      end)
      |> Repo.transaction()
      |> WriteSupport.unwrap_multi(:session)
    end
  rescue
    Ecto.ConstraintError ->
      {:error,
       WriteSupport.error_changeset(
         %Session{},
         :week_mask,
         "change conflicts with existing placements"
       )}
  end

  def change_session(%Session{} = session, attrs \\ %{}), do: Session.changeset(session, attrs)

  @doc """
  Finds possible duplicate shared classes.

  Candidates share a component, teacher, weeks and duration but have different
  groups. Independent parallel classes can also match, so review is required.
  """
  def merge_candidates(term_id) do
    term_id
    |> list_sessions()
    |> Enum.reject(& &1.automatic_weeks)
    |> Enum.group_by(&{&1.course_component_id, &1.teacher_id, &1.week_mask, &1.duration_slots})
    |> Enum.filter(fn {_key, sessions} ->
      # Repeated weekly series of one requirement are intentional. Only
      # different attending groups can suggest a duplicate shared class.
      sessions
      |> Enum.map(fn session -> Enum.sort(Enum.map(session.cohorts, & &1.id)) end)
      |> Enum.uniq()
      |> length() > 1
    end)
    |> Enum.map(fn {{component_id, _teacher, _mask, _duration}, sessions} ->
      %{
        course_component_id: component_id,
        course_code: hd(sessions).course_component.course.code,
        course_title: hd(sessions).course_component.course.title,
        course: hd(sessions).course_component.course,
        kind: hd(sessions).course_component.kind,
        teacher: hd(sessions).teacher.name,
        session_ids: Enum.map(sessions, & &1.id),
        cohorts:
          sessions
          |> Enum.flat_map(& &1.cohorts)
          |> Enum.map(& &1.name)
          |> Enum.uniq()
          |> Enum.sort()
      }
    end)
    |> Enum.sort_by(&{&1.course_title, &1.course_component_id})
  end

  @doc false
  def delete_generated_session(%Session{} = session) do
    WriteSupport.transaction_result(fn ->
      Repo.one!(from t in Term, where: t.id == ^session.term_id, lock: "FOR UPDATE")

      case Repo.one(from s in Session, where: s.id == ^session.id, lock: "FOR UPDATE") do
        nil ->
          {:error, :not_found}

        locked_session ->
          placed_in_active_plan =
            from p in Placement,
              join: plan in assoc(p, :plan),
              where: p.session_id == ^locked_session.id and plan.status == "active"

          # Deleting the session would cascade its exceptions away and silently
          # drop announced one-off occurrences from the published schedule.
          has_active_exceptions =
            from e in ScheduleException,
              where: e.session_id == ^locked_session.id and e.status == "active"

          cond do
            Repo.exists?(placed_in_active_plan) ->
              {:error, {:conflict, "session is placed in the active published plan"}}

            Repo.exists?(has_active_exceptions) ->
              {:error,
               {:conflict, "session has active schedule exceptions; revert or delete them first"}}

            true ->
              Repo.delete(locked_session)
          end
      end
    end)
  end

  defp replace_session_cohorts(repo, session_id, cohort_ids) do
    repo.delete_all(from c in SessionCohort, where: c.session_id == ^session_id)

    rows =
      Enum.map(cohort_ids, fn cohort_id ->
        %{session_id: session_id, cohort_id: cohort_id}
      end)

    {count, _} = repo.insert_all(SessionCohort, rows)
    {:ok, count}
  end
end
