defmodule NeuZeit.Catalog do
  @moduledoc """
  Catalog and demand-layer data entry.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias NeuZeit.Catalog

  alias NeuZeit.Catalog.{
    Building,
    Cohort,
    ComponentAllowedRoom,
    Course,
    CourseComponent,
    CourseTranslation,
    Room,
    Session,
    SessionCohort,
    SlotProfile,
    Teacher,
    TeacherAvailabilityCell,
    Term
  }

  alias NeuZeit.Constraints.{Hard, Occurrence}
  alias NeuZeit.Planning.{Placement, Plan, ScheduleException}
  alias NeuZeit.Repo

  def list_terms, do: Repo.all(from t in Term, order_by: [asc: t.starts_on, asc: t.name])
  def get_term!(id), do: Repo.get!(Term, id)
  def create_term(attrs), do: %Term{} |> Term.changeset(attrs) |> Repo.insert()

  def update_term(%Term{} = term, attrs) do
    update_locked_term(term.id, fn _locked_term -> attrs end)
  end

  def delete_term(%Term{} = term), do: Repo.delete(term)

  def add_excluded_date(%Term{} = term, %Date{} = date) do
    update_locked_term(term.id, fn locked_term ->
      %{excluded_dates: Enum.uniq([date | locked_term.excluded_dates])}
    end)
  end

  def remove_excluded_date(%Term{} = term, %Date{} = date) do
    update_locked_term(term.id, fn locked_term ->
      %{excluded_dates: List.delete(locked_term.excluded_dates, date)}
    end)
  end

  def list_buildings, do: Repo.all(from b in Building, order_by: b.name)
  def get_building!(id), do: Repo.get!(Building, id)
  def create_building(attrs), do: %Building{} |> Building.changeset(attrs) |> Repo.insert()

  def update_building(%Building{} = building, attrs),
    do: building |> Building.changeset(attrs) |> Repo.update()

  def delete_building(%Building{} = building), do: Repo.delete(building)

  def list_rooms do
    Repo.all(from r in Room, order_by: r.name, preload: [:building])
  end

  def get_room!(id), do: Room |> Repo.get!(id) |> Repo.preload(:building)
  def create_room(attrs), do: %Room{} |> Room.changeset(attrs) |> Repo.insert()
  def update_room(%Room{} = room, attrs), do: room |> Room.changeset(attrs) |> Repo.update()
  def delete_room(%Room{} = room), do: Repo.delete(room)

  def list_courses do
    Repo.all(from c in Course, order_by: c.code, preload: [:components])
  end

  def list_courses(locale) when is_binary(locale) do
    Repo.all(
      from c in Course,
        left_join: t in CourseTranslation,
        on: t.course_id == c.id and t.locale == ^locale,
        order_by: c.code,
        select: %{
          id: c.id,
          code: c.code,
          credits: c.credits,
          title: fragment("coalesce(?, ?)", t.title, c.title)
        }
    )
  end

  def get_course!(id), do: Course |> Repo.get!(id) |> Repo.preload(:components)
  def create_course(attrs), do: %Course{} |> Course.changeset(attrs) |> Repo.insert()

  def update_course(%Course{} = course, attrs),
    do: course |> Course.changeset(attrs) |> Repo.update()

  def delete_course(%Course{} = course), do: Repo.delete(course)

  def create_course_translation(attrs) do
    %CourseTranslation{} |> CourseTranslation.changeset(attrs) |> Repo.insert()
  end

  def list_course_components do
    Repo.all(
      from c in CourseComponent,
        order_by: [asc: c.course_id, asc: c.kind],
        preload: [:course, :allowed_rooms]
    )
  end

  def get_course_component!(id) do
    CourseComponent |> Repo.get!(id) |> Repo.preload([:course, :allowed_rooms])
  end

  def create_course_component(attrs) do
    with {:ok, allowed_room_ids} <-
           normalize_existing_ids(
             attr(attrs, :allowed_room_ids, []),
             :allowed_room_ids,
             %CourseComponent{},
             Room
           ) do
      Multi.new()
      |> Multi.insert(:component, CourseComponent.changeset(%CourseComponent{}, attrs))
      |> Multi.run(:allowed_rooms, fn repo, %{component: component} ->
        replace_allowed_rooms(repo, component.id, allowed_room_ids)
      end)
      |> Repo.transaction()
      |> unwrap_multi(:component)
    end
  end

  def update_course_component(%CourseComponent{} = component, attrs) do
    with {:ok, allowed_room_ids} <-
           maybe_normalize_existing_ids(
             attr(attrs, :allowed_room_ids),
             :allowed_room_ids,
             %CourseComponent{},
             Room
           ) do
      transaction_result(fn ->
        current =
          Repo.one!(
            from c in CourseComponent,
              where: c.id == ^component.id,
              lock: "FOR UPDATE"
          )

        term_ids =
          if is_nil(allowed_room_ids),
            do: [],
            else: lock_component_terms(current.id)

        with {:ok, updated} <- current |> CourseComponent.changeset(attrs) |> Repo.update(),
             {:ok, _count} <- maybe_replace_allowed_rooms(updated.id, allowed_room_ids),
             :ok <- validate_component_schedules(term_ids, updated.id) do
          {:ok, updated}
        end
      end)
    end
  end

  def delete_course_component(%CourseComponent{} = component), do: Repo.delete(component)

  def list_teachers, do: Repo.all(from t in Teacher, order_by: t.name)
  def get_teacher!(id), do: Repo.get!(Teacher, id)
  def create_teacher(attrs), do: %Teacher{} |> Teacher.changeset(attrs) |> Repo.insert()

  def update_teacher(%Teacher{} = teacher, attrs),
    do: teacher |> Teacher.changeset(attrs) |> Repo.update()

  def delete_teacher(%Teacher{} = teacher), do: Repo.delete(teacher)

  def list_teacher_availability(term_id, teacher_id) do
    Repo.all(
      from cell in TeacherAvailabilityCell,
        where: cell.term_id == ^term_id and cell.teacher_id == ^teacher_id,
        order_by: [asc: cell.day, asc: cell.slot]
    )
  end

  @doc """
  Atomically replaces a teacher's recurring weekly availability for one term.

  An empty cell list means unrestricted availability. Once at least one cell is
  present, every occupied slot of the teacher's sessions must be in the allow-list.
  Existing draft and active placements are revalidated before the change commits.
  """
  def replace_teacher_availability(term_id, teacher_id, cells) when is_list(cells) do
    transaction_result(fn ->
      Repo.one!(from term in Term, where: term.id == ^term_id, lock: "FOR UPDATE")
      Repo.one!(from teacher in Teacher, where: teacher.id == ^teacher_id, lock: "FOR UPDATE")

      Repo.delete_all(
        from cell in TeacherAvailabilityCell,
          where: cell.term_id == ^term_id and cell.teacher_id == ^teacher_id
      )

      with :ok <- insert_teacher_availability(term_id, teacher_id, cells),
           :ok <- validate_teacher_availability_sessions(term_id, teacher_id),
           :ok <- validate_teacher_availability_schedules(term_id, teacher_id),
           :ok <- validate_active_projection(Repo, term_id) do
        {:ok, list_teacher_availability(term_id, teacher_id)}
      end
    end)
  end

  def replace_teacher_availability(_term_id, _teacher_id, _cells) do
    {:error,
     error_changeset(
       %TeacherAvailabilityCell{},
       :availability,
       "cells must be a list of day/slot maps"
     )}
  end

  def list_cohorts, do: Repo.all(from c in Cohort, order_by: c.name)
  def get_cohort!(id), do: Repo.get!(Cohort, id)
  def create_cohort(attrs), do: %Cohort{} |> Cohort.changeset(attrs) |> Repo.insert()

  def update_cohort(%Cohort{} = cohort, attrs),
    do: cohort |> Cohort.changeset(attrs) |> Repo.update()

  def delete_cohort(%Cohort{} = cohort), do: Repo.delete(cohort)

  def list_slot_profiles(term_id \\ nil) do
    query =
      from profile in SlotProfile,
        order_by: [asc: profile.term_id, asc: profile.name],
        preload: [:term, :cells]

    query =
      if term_id,
        do: from(profile in query, where: profile.term_id == ^term_id),
        else: query

    Repo.all(query)
  end

  def get_slot_profile!(id),
    do: SlotProfile |> Repo.get!(id) |> Repo.preload([:term, :cells])

  def create_slot_profile(attrs) do
    %SlotProfile{}
    |> SlotProfile.changeset(attrs)
    |> Repo.insert()
    |> preload_result([:term, :cells])
  end

  def update_slot_profile(%SlotProfile{} = profile, attrs) do
    transaction_result(fn ->
      Repo.one!(from t in Term, where: t.id == ^profile.term_id, lock: "FOR UPDATE")

      current =
        Repo.one!(from p in SlotProfile, where: p.id == ^profile.id, lock: "FOR UPDATE")
        |> Repo.preload(:cells)

      with {:ok, updated} <- current |> SlotProfile.update_changeset(attrs) |> Repo.update(),
           :ok <- validate_slot_profile_durations(updated),
           :ok <- validate_slot_profile_schedules(updated) do
        {:ok, Repo.preload(updated, [:term, :cells], force: true)}
      end
    end)
  end

  def delete_slot_profile(%SlotProfile{} = profile), do: Repo.delete(profile)

  @doc """
  Creates the reusable DKU time profiles inferred from the legacy timetable.

  The operation is idempotent by profile name, so administrators can safely run
  it once for every new term and then edit or clone the resulting profiles.
  """
  def ensure_default_slot_profiles(%Term{} = term) do
    transaction_result(fn ->
      Repo.one!(from t in Term, where: t.id == ^term.id, lock: "FOR UPDATE")

      existing_names =
        Repo.all(from p in SlotProfile, where: p.term_id == ^term.id, select: p.name)
        |> MapSet.new()

      default_slot_profiles()
      |> Enum.reject(fn {name, _cells} -> MapSet.member?(existing_names, name) end)
      |> Enum.reduce_while(:ok, fn {name, cells}, _acc ->
        attrs = %{term_id: term.id, name: name, cells: cells}

        case %SlotProfile{} |> SlotProfile.changeset(attrs) |> Repo.insert() do
          {:ok, _profile} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        :ok -> {:ok, list_slot_profiles(term.id)}
        {:error, _reason} = error -> error
      end
    end)
  end

  def list_sessions do
    Repo.all(
      from s in Session,
        order_by: [asc: s.term_id, asc: s.id],
        preload: [
          :term,
          :cohorts,
          teacher: [:availability_cells],
          slot_profile: [:cells],
          course_component: [:course, :allowed_rooms]
        ]
    )
  end

  def get_session!(id) do
    Session
    |> Repo.get!(id)
    |> Repo.preload([
      :term,
      :cohorts,
      teacher: [:availability_cells],
      slot_profile: [:cells],
      course_component: [:course, :allowed_rooms]
    ])
  end

  def create_session(attrs) do
    with {:ok, cohort_ids} <-
           normalize_existing_ids(attr(attrs, :cohort_ids, []), :cohort_ids, %Session{}, Cohort) do
      Multi.new()
      |> Multi.run(:term_lock, fn repo, _changes ->
        case Ecto.UUID.cast(attr(attrs, :term_id)) do
          {:ok, term_id} ->
            case repo.one(from t in Term, where: t.id == ^term_id, lock: "FOR UPDATE") do
              %Term{} = term -> {:ok, term}
              nil -> {:error, error_changeset(%Session{}, :term_id, "does not exist")}
            end

          :error ->
            # Let the session changeset return the canonical blank/invalid error.
            {:ok, :invalid_term_id}
        end
      end)
      |> Multi.insert(:session, Session.changeset(%Session{}, attrs))
      |> Multi.run(:cohorts, fn repo, %{session: session} ->
        replace_session_cohorts(repo, session.id, cohort_ids)
      end)
      |> Repo.transaction()
      |> unwrap_multi(:session)
    end
  end

  def update_session(%Session{} = session, attrs) do
    with {:ok, cohort_ids} <-
           maybe_normalize_existing_ids(attr(attrs, :cohort_ids), :cohort_ids, %Session{}, Cohort) do
      Multi.new()
      # Session edits and exception mutations share the term lock because both
      # can change the published dated schedule.
      |> Multi.run(:term_lock, fn repo, _changes ->
        {:ok, repo.one!(from t in Term, where: t.id == ^session.term_id, lock: "FOR UPDATE")}
      end)
      |> Multi.update(:session, Session.update_changeset(session, attrs))
      |> maybe_replace(:cohorts, cohort_ids, fn repo, %{session: session} ->
        replace_session_cohorts(repo, session.id, cohort_ids)
      end)
      |> Multi.run(:placements, fn repo, %{session: updated_session} ->
        sync_and_revalidate_plans(repo, session, updated_session, not is_nil(cohort_ids))
      end)
      |> Repo.transaction()
      |> unwrap_multi(:session)
    end
  rescue
    Ecto.ConstraintError ->
      {:error,
       error_changeset(%Session{}, :week_mask, "change conflicts with existing placements")}
  end

  def delete_session(%Session{} = session) do
    transaction_result(fn ->
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

  defp sync_and_revalidate_plans(repo, old_session, session, cohorts_replaced?) do
    mask_changed? = session.week_mask != old_session.week_mask

    duration_changed? = session.duration_slots != old_session.duration_slots

    conflict_fields_changed? =
      mask_changed? or session.teacher_id != old_session.teacher_id or
        session.course_component_id != old_session.course_component_id or duration_changed? or
        session.slot_profile_id != old_session.slot_profile_id

    if not conflict_fields_changed? and not cohorts_replaced? do
      {:ok, :unchanged}
    else
      plan_ids =
        repo.all(
          from p in Placement,
            join: plan in assoc(p, :plan),
            where: p.session_id == ^session.id and plan.status in ["draft", "active"],
            distinct: true,
            select: p.plan_id
        )

      with :ok <- validate_resynced_plans(repo, session, plan_ids),
           :ok <-
             validate_active_projection(
               repo,
               session.term_id,
               {session.id, session.week_mask, session.duration_slots}
             ) do
        if mask_changed? or duration_changed? do
          now = DateTime.utc_now() |> DateTime.truncate(:second)

          from(p in Placement, where: p.session_id == ^session.id and p.plan_id in ^plan_ids)
          |> repo.update_all(
            set: [
              week_mask: session.week_mask,
              duration_slots: session.duration_slots,
              updated_at: now
            ]
          )
        end

        {:ok, :revalidated}
      end
    end
  end

  defp validate_resynced_plans(repo, session, plan_ids) do
    Enum.reduce_while(plan_ids, :ok, fn plan_id, _acc ->
      placements =
        repo.all(
          from p in Placement,
            where: p.plan_id == ^plan_id,
            preload: [
              :room,
              session: [
                :cohorts,
                teacher: [:availability_cells],
                slot_profile: [:cells],
                course_component: [:allowed_rooms]
              ]
            ]
        )
        |> Enum.map(fn placement ->
          if placement.session_id == session.id do
            %{
              placement
              | week_mask: session.week_mask,
                duration_slots: session.duration_slots
            }
          else
            placement
          end
        end)

      case Hard.validate_placements(placements) do
        :ok -> {:cont, :ok}
        {:error, errors} -> {:halt, {:error, %{errors: errors}}}
      end
    end)
  end

  defp update_locked_term(term_id, attrs_fun) do
    transaction_result(fn ->
      case Repo.one(from t in Term, where: t.id == ^term_id, lock: "FOR UPDATE") do
        nil ->
          {:error, :not_found}

        locked_term ->
          changeset = Term.changeset(locked_term, attrs_fun.(locked_term))

          with {:ok, updated_term} <- Repo.update(changeset),
               :ok <- maybe_validate_term_projection(updated_term, changeset) do
            {:ok, updated_term}
          end
      end
    end)
  end

  defp maybe_validate_term_projection(term, changeset) do
    if Enum.any?([:starts_on, :ends_on, :excluded_dates], &Map.has_key?(changeset.changes, &1)) do
      validate_active_projection(Repo, term.id)
    else
      :ok
    end
  end

  defp lock_component_terms(component_id) do
    # A session can concurrently move onto this component. Locking the complete
    # ordered term set first makes the subsequent affected-term query stable and
    # preserves the same serialization point used by session and exception edits.
    Repo.all(from t in Term, order_by: t.id, lock: "FOR UPDATE", select: t.id)

    Repo.all(
      from s in Session,
        where: s.course_component_id == ^component_id,
        distinct: true,
        order_by: s.term_id,
        select: s.term_id
    )
  end

  defp maybe_replace_allowed_rooms(_component_id, nil), do: {:ok, :unchanged}

  defp maybe_replace_allowed_rooms(component_id, room_ids) do
    replace_allowed_rooms(Repo, component_id, room_ids)
  end

  defp validate_component_schedules(term_ids, component_id) do
    Enum.reduce_while(term_ids, :ok, fn term_id, _acc ->
      with :ok <- validate_component_plans(term_id, component_id),
           :ok <- validate_active_projection(Repo, term_id) do
        {:cont, :ok}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_slot_profile_schedules(profile) do
    plans =
      Repo.all(
        from plan in Plan,
          join: placement in Placement,
          on: placement.plan_id == plan.id,
          join: session in Session,
          on: session.id == placement.session_id,
          where: plan.term_id == ^profile.term_id and plan.status in ["draft", "active"],
          where: session.slot_profile_id == ^profile.id,
          distinct: true,
          preload: [
            placements: [
              :room,
              session: [
                :cohorts,
                teacher: [:availability_cells],
                slot_profile: [:cells],
                course_component: [:allowed_rooms]
              ]
            ]
          ]
      )

    with :ok <- validate_plans(plans),
         :ok <- validate_active_projection(Repo, profile.term_id) do
      :ok
    end
  end

  defp validate_slot_profile_durations(profile) do
    slots_count = length(NeuZeit.Config.grid!().slots)
    earliest_start = profile.cells |> Enum.map(& &1.slot) |> Enum.min(fn -> slots_count + 1 end)

    impossible_session? =
      Repo.exists?(
        from session in Session,
          where: session.slot_profile_id == ^profile.id,
          where: session.duration_slots > ^(slots_count - earliest_start + 1)
      )

    if impossible_session? do
      {:error,
       error_changeset(
         profile,
         :cells,
         "must contain a start cell that fits every assigned session duration"
       )}
    else
      :ok
    end
  end

  defp validate_plans(plans) do
    Enum.reduce_while(plans, :ok, fn plan, _acc ->
      case Hard.validate_placements(plan.placements) do
        :ok -> {:cont, :ok}
        {:error, errors} -> {:halt, {:error, %{errors: errors}}}
      end
    end)
  end

  defp validate_component_plans(term_id, component_id) do
    Repo.all(
      from plan in Plan,
        join: placement in Placement,
        on: placement.plan_id == plan.id,
        join: session in Session,
        on: session.id == placement.session_id,
        where: plan.term_id == ^term_id and plan.status in ["draft", "active"],
        where: session.course_component_id == ^component_id,
        distinct: true,
        preload: [
          placements: [
            :room,
            session: [
              :cohorts,
              teacher: [:availability_cells],
              slot_profile: [:cells],
              course_component: [:allowed_rooms]
            ]
          ]
        ]
    )
    |> Enum.reduce_while(:ok, fn plan, _acc ->
      case Hard.validate_placements(plan.placements) do
        :ok -> {:cont, :ok}
        {:error, errors} -> {:halt, {:error, %{errors: errors}}}
      end
    end)
  end

  defp validate_active_projection(repo, term_id, session_override \\ nil) do
    term = repo.get!(Term, term_id)

    placements =
      repo.all(
        from p in Placement,
          join: plan in assoc(p, :plan),
          where: plan.term_id == ^term_id and plan.status == "active"
      )
      |> override_session_snapshot(session_override)

    exceptions =
      repo.all(
        from e in ScheduleException,
          where: e.term_id == ^term_id and e.status == "active"
      )

    Occurrence.validate(term, placements, exceptions, require_origins: true)
  end

  defp override_session_snapshot(placements, nil), do: placements

  defp override_session_snapshot(placements, {session_id, week_mask, duration_slots}) do
    Enum.map(placements, fn placement ->
      if placement.session_id == session_id,
        do: %{placement | week_mask: week_mask, duration_slots: duration_slots},
        else: placement
    end)
  end

  defp default_slot_profiles do
    [
      {"ANY", cells(1..6, 1..6)},
      {"DAYTIME_ANY", cells(1..5, 1..4)},
      {"DE_EARLY", cells([1, 3, 5], 1..2)},
      {"DE_LATE", cells([1, 3, 5], 3..4)},
      {"EN_EARLY", cells([2, 4], 1..2)},
      {"EN_LATE", cells([2, 4], 3..4)},
      {"EN_SATURDAY", cells([6], 1..6)},
      {"KZ_LATE", cells(1..5, 3..6)},
      {"PE_EDGE", cells(1..5, [1, 5])}
    ]
  end

  defp cells(days, slots) do
    for day <- days, slot <- slots, do: %{day: day, slot: slot}
  end

  defp replace_allowed_rooms(repo, component_id, room_ids) do
    repo.delete_all(from r in ComponentAllowedRoom, where: r.component_id == ^component_id)

    rows =
      Enum.map(room_ids, fn room_id ->
        %{component_id: component_id, room_id: room_id}
      end)

    {count, _} = repo.insert_all(ComponentAllowedRoom, rows)
    {:ok, count}
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

  defp insert_teacher_availability(term_id, teacher_id, cells) do
    if Enum.all?(cells, &is_map/1) do
      cells
      |> Enum.uniq_by(fn cell -> {attr(cell, :day), attr(cell, :slot)} end)
      |> Enum.reduce_while(:ok, fn cell, _acc ->
        attrs = %{
          term_id: term_id,
          teacher_id: teacher_id,
          day: attr(cell, :day),
          slot: attr(cell, :slot)
        }

        case %TeacherAvailabilityCell{}
             |> TeacherAvailabilityCell.changeset(attrs)
             |> Repo.insert() do
          {:ok, _cell} -> {:cont, :ok}
          {:error, changeset} -> {:halt, {:error, changeset}}
        end
      end)
    else
      {:error,
       error_changeset(
         %TeacherAvailabilityCell{},
         :availability,
         "each cell must be a day/slot map"
       )}
    end
  end

  defp validate_teacher_availability_sessions(term_id, teacher_id) do
    availability_cells = list_teacher_availability(term_id, teacher_id)

    invalid_session =
      Repo.all(
        from session in Session,
          where: session.term_id == ^term_id and session.teacher_id == ^teacher_id,
          preload: [slot_profile: [:cells]]
      )
      |> Enum.find(fn session ->
        profile_cells = if session.slot_profile, do: session.slot_profile.cells, else: nil

        not TeacherAvailabilityCell.schedulable?(
          availability_cells,
          profile_cells,
          session.duration_slots
        )
      end)

    case invalid_session do
      nil ->
        :ok

      session ->
        {:error,
         error_changeset(
           %TeacherAvailabilityCell{},
           :availability,
           "leaves no valid start for session #{session.id}"
         )}
    end
  end

  defp validate_teacher_availability_schedules(term_id, teacher_id) do
    Repo.all(
      from plan in Plan,
        join: placement in Placement,
        on: placement.plan_id == plan.id,
        join: session in Session,
        on: session.id == placement.session_id,
        where: plan.term_id == ^term_id and plan.status in ["draft", "active"],
        where: session.teacher_id == ^teacher_id,
        distinct: true,
        preload: [
          placements: [
            :room,
            session: [
              :cohorts,
              teacher: [:availability_cells],
              slot_profile: [:cells],
              course_component: [:allowed_rooms]
            ]
          ]
        ]
    )
    |> validate_plans()
  end

  defp maybe_replace(multi, _name, nil, _fun), do: multi
  defp maybe_replace(multi, name, _ids, fun), do: Multi.run(multi, name, fun)

  defp maybe_normalize_existing_ids(nil, _field, _schema, _repo_schema), do: {:ok, nil}

  defp maybe_normalize_existing_ids(ids, field, schema, repo_schema) do
    normalize_existing_ids(ids, field, schema, repo_schema)
  end

  defp normalize_existing_ids(ids, field, schema, repo_schema) when is_list(ids) do
    with {:ok, ids} <- cast_ids(ids, field, schema),
         :ok <- require_ids(ids, field, schema),
         :ok <- ensure_existing_ids(ids, field, schema, repo_schema) do
      {:ok, ids}
    end
  end

  defp normalize_existing_ids(_ids, field, schema, _repo_schema) do
    {:error, Catalog.error_changeset(schema, field, "must be a non-empty list of ids")}
  end

  defp cast_ids(ids, field, schema) do
    ids
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
      case Ecto.UUID.cast(id) do
        {:ok, uuid} ->
          {:cont, {:ok, [uuid | acc]}}

        :error ->
          {:halt, {:error, Catalog.error_changeset(schema, field, "contains invalid ids")}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, ids |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp require_ids(ids, _field, _schema) when is_list(ids) and ids != [], do: :ok

  defp require_ids(_ids, field, schema) do
    {:error, Catalog.error_changeset(schema, field, "must be a non-empty list of ids")}
  end

  defp ensure_existing_ids(ids, field, schema, repo_schema) do
    existing_ids =
      repo_schema
      |> where([record], record.id in ^ids)
      |> select([record], record.id)
      |> Repo.all()
      |> MapSet.new()

    if Enum.all?(ids, &MapSet.member?(existing_ids, &1)) do
      :ok
    else
      {:error, Catalog.error_changeset(schema, field, "contains unknown ids")}
    end
  end

  def error_changeset(schema, field, message) do
    schema
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(field, message)
  end

  defp transaction_result(fun) do
    case Repo.transaction(fn ->
           case fun.() do
             {:ok, result} -> result
             :ok -> :ok
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp unwrap_multi({:ok, result}, key), do: {:ok, Map.fetch!(result, key)}
  defp unwrap_multi({:error, _step, reason, _changes}, _key), do: {:error, reason}
  defp unwrap_multi({:error, reason}, _key), do: {:error, reason}

  defp preload_result({:ok, record}, associations),
    do: {:ok, Repo.preload(record, associations)}

  defp preload_result({:error, reason}, _associations), do: {:error, reason}

  defp attr(attrs, key, default \\ nil)

  defp attr(attrs, key, default) when is_atom(key) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end
end
