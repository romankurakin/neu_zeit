defmodule NeuZeit.Catalog do
  @moduledoc "Catalog records and scheduling inputs."
  import Ecto.Query, warn: false
  alias NeuZeit.Catalog.Building
  alias NeuZeit.Catalog.Cohort
  alias NeuZeit.Catalog.Course
  alias NeuZeit.Catalog.CourseTranslation
  alias NeuZeit.Catalog.Room
  alias NeuZeit.Catalog.Session
  alias NeuZeit.Catalog.Teacher
  alias NeuZeit.Catalog.Term
  alias NeuZeit.Repo

  def list_terms, do: Repo.all(from t in Term, order_by: [asc: t.starts_on, asc: t.name])

  def get_term!(id), do: Repo.get!(Term, id)

  def create_term(attrs), do: %Term{} |> Term.changeset(attrs) |> Repo.insert()

  def update_term(%Term{} = term, attrs) do
    update_locked_term(term.id, fn _locked_term -> attrs end)
  end

  def delete_term(%Term{} = term), do: Repo.delete(term)

  @doc """
  Builds a term changeset for form rendering.
  """
  def change_term(%Term{} = term, attrs \\ %{}), do: Term.changeset(term, attrs)

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

  def change_building(%Building{} = building, attrs \\ %{}),
    do: Building.changeset(building, attrs)

  def list_rooms do
    Repo.all(from r in Room, order_by: r.name, preload: [:building])
  end

  def get_room!(id), do: Room |> Repo.get!(id) |> Repo.preload(:building)

  def create_room(attrs), do: %Room{} |> Room.changeset(attrs) |> Repo.insert()

  def update_room(%Room{} = room, attrs), do: room |> Room.changeset(attrs) |> Repo.update()

  def delete_room(%Room{} = room), do: Repo.delete(room)

  def change_room(%Room{} = room, attrs \\ %{}), do: Room.changeset(room, attrs)

  def list_courses do
    Repo.all(
      from c in Course,
        order_by: [c.title, c.id],
        preload: [:translations, components: [teaching_type: :translations]]
    )
  end

  def list_courses(locale) when is_binary(locale) do
    Repo.all(
      from c in Course,
        left_join: t in CourseTranslation,
        on: t.course_id == c.id and t.locale == ^locale,
        order_by: [fragment("coalesce(?, ?)", t.title, c.title), c.id],
        select: %{
          id: c.id,
          code: c.code,
          title: fragment("coalesce(?, ?)", t.title, c.title)
        }
    )
  end

  def get_course!(id),
    do:
      Course
      |> Repo.get!(id)
      |> Repo.preload([:translations, components: [teaching_type: :translations]])

  def create_course(attrs),
    do:
      %Course{}
      |> Course.changeset(attrs)
      |> Repo.insert()
      |> NeuZeit.Catalog.WriteSupport.preload_result(:translations)

  def update_course(%Course{} = course, attrs),
    do:
      course
      |> Course.changeset(attrs)
      |> Repo.update()
      |> NeuZeit.Catalog.WriteSupport.preload_result(:translations)

  def delete_course(%Course{} = course), do: Repo.delete(course)

  def change_course(%Course{} = course, attrs \\ %{}), do: Course.changeset(course, attrs)

  def create_course_translation(attrs) do
    %CourseTranslation{} |> CourseTranslation.changeset(attrs) |> Repo.insert()
  end

  @doc """
  Lists a course's translations, ordered by locale.
  """
  def list_course_translations(course_id) do
    Repo.all(from t in CourseTranslation, where: t.course_id == ^course_id, order_by: t.locale)
  end

  @doc """
  Fetches a course translation by locale. Each course has at most one title per locale.
  """
  def get_course_translation(course_id, locale) do
    Repo.one(
      from t in CourseTranslation, where: t.course_id == ^course_id and t.locale == ^locale
    )
  end

  def update_course_translation(%CourseTranslation{} = translation, attrs) do
    translation |> CourseTranslation.changeset(attrs) |> Repo.update()
  end

  def delete_course_translation(%CourseTranslation{} = translation), do: Repo.delete(translation)

  def change_course_translation(%CourseTranslation{} = translation, attrs \\ %{}),
    do: CourseTranslation.changeset(translation, attrs)

  @doc """
  Returns reference counts for registry screens without a query per row.

  Room counts cover all terms. Session-derived counts use `term_id` when supplied.

  Returns `%{rooms: %{id => %{components: n, placements: n}}, components: %{id => n},
  teachers: %{id => n}, cohorts: %{id => n}, slot_profiles: %{id => n}}`.
  An absent ID has a count of zero.
  """
  def usage_counts(term_id \\ nil) do
    %{
      rooms: room_usage(),
      components: tally(session_scope(term_id), :course_component_id),
      teachers: tally(session_scope(term_id), :teacher_id),
      cohorts: cohort_usage(term_id),
      slot_profiles: tally(session_scope(term_id), :slot_profile_id)
    }
  end

  defp session_scope(nil), do: from(s in Session)

  defp session_scope(term_id), do: from(s in Session, where: s.term_id == ^term_id)

  defp tally(scope, field) do
    scope
    |> group_by(^field)
    |> select([s], {field(s, ^field), count()})
    |> Repo.all()
    |> Map.new()
  end

  defp cohort_usage(term_id) do
    session_scope(term_id)
    |> join(:inner, [s], c in "session_cohorts", on: c.session_id == s.id)
    |> group_by([_s, c], c.cohort_id)
    |> select([_s, c], {type(c.cohort_id, Ecto.UUID), count()})
    |> Repo.all()
    |> Map.new()
  end

  defp room_usage do
    components =
      from(r in "component_allowed_rooms",
        group_by: r.room_id,
        select: {type(r.room_id, Ecto.UUID), count()}
      )
      |> Repo.all()
      |> Map.new()

    placements =
      from(p in NeuZeit.Planning.Placement,
        group_by: p.room_id,
        select: {p.room_id, count()}
      )
      |> Repo.all()
      |> Map.new()

    components
    |> Map.keys()
    |> Kernel.++(Map.keys(placements))
    |> Enum.uniq()
    |> Map.new(fn room_id ->
      {room_id,
       %{
         components: Map.get(components, room_id, 0),
         placements: Map.get(placements, room_id, 0)
       }}
    end)
  end

  def list_teachers, do: Repo.all(from t in Teacher, order_by: t.name)

  def get_teacher!(id), do: Repo.get!(Teacher, id)

  def create_teacher(attrs), do: %Teacher{} |> Teacher.changeset(attrs) |> Repo.insert()

  def update_teacher(%Teacher{} = teacher, attrs),
    do: teacher |> Teacher.changeset(attrs) |> Repo.update()

  def delete_teacher(%Teacher{} = teacher) do
    teacher
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.foreign_key_constraint(:id,
      name: :schedule_exceptions_new_teacher_id_fkey,
      message: "is used by a one-off change"
    )
    |> Repo.delete()
  end

  def change_teacher(%Teacher{} = teacher, attrs \\ %{}), do: Teacher.changeset(teacher, attrs)

  def list_cohorts, do: Repo.all(from c in Cohort, order_by: c.name)

  def get_cohort!(id), do: Repo.get!(Cohort, id)

  def create_cohort(attrs), do: %Cohort{} |> Cohort.changeset(attrs) |> Repo.insert()

  def update_cohort(%Cohort{} = cohort, attrs),
    do: cohort |> Cohort.changeset(attrs) |> Repo.update()

  def delete_cohort(%Cohort{} = cohort), do: Repo.delete(cohort)

  def change_cohort(%Cohort{} = cohort, attrs \\ %{}), do: Cohort.changeset(cohort, attrs)

  defp update_locked_term(term_id, attrs_fun) do
    NeuZeit.Catalog.WriteSupport.transaction_result(fn ->
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
      NeuZeit.Catalog.ScheduleValidation.validate_active_projection(Repo, term.id)
    else
      :ok
    end
  end

  defdelegate list_course_components(), to: NeuZeit.Catalog.CourseComponents

  defdelegate list_teaching_types(), to: NeuZeit.Catalog.TeachingTypes
  defdelegate get_teaching_type!(id), to: NeuZeit.Catalog.TeachingTypes
  defdelegate create_teaching_type(attrs), to: NeuZeit.Catalog.TeachingTypes
  defdelegate update_teaching_type(teaching_type, attrs), to: NeuZeit.Catalog.TeachingTypes
  defdelegate change_teaching_type(teaching_type, attrs \\ %{}), to: NeuZeit.Catalog.TeachingTypes
  defdelegate delete_teaching_type(teaching_type), to: NeuZeit.Catalog.TeachingTypes
  defdelegate teaching_type_usage(), to: NeuZeit.Catalog.TeachingTypes
  defdelegate get_course_component!(id), to: NeuZeit.Catalog.CourseComponents
  defdelegate create_course_component(attrs), to: NeuZeit.Catalog.CourseComponents
  defdelegate update_course_component(component, attrs), to: NeuZeit.Catalog.CourseComponents
  defdelegate delete_course_component(component), to: NeuZeit.Catalog.CourseComponents

  defdelegate change_course_component(component, attrs \\ %{}),
    to: NeuZeit.Catalog.CourseComponents

  defdelegate list_teacher_availability(term_id, teacher_id),
    to: NeuZeit.Catalog.TeacherAvailability

  defdelegate replace_teacher_availability(term_id, teacher_id, cells),
    to: NeuZeit.Catalog.TeacherAvailability

  defdelegate list_slot_profiles(term_id \\ nil), to: NeuZeit.Catalog.SlotProfiles
  defdelegate get_slot_profile!(id, term_id), to: NeuZeit.Catalog.SlotProfiles
  defdelegate get_slot_profile!(id), to: NeuZeit.Catalog.SlotProfiles
  defdelegate create_slot_profile(attrs), to: NeuZeit.Catalog.SlotProfiles
  defdelegate update_slot_profile(profile, attrs), to: NeuZeit.Catalog.SlotProfiles
  defdelegate delete_slot_profile(profile), to: NeuZeit.Catalog.SlotProfiles
  defdelegate change_slot_profile(profile, attrs \\ %{}), to: NeuZeit.Catalog.SlotProfiles
  defdelegate ensure_default_slot_profiles(term), to: NeuZeit.Catalog.SlotProfiles
  defdelegate list_sessions(), to: NeuZeit.Catalog.Sessions
  defdelegate list_sessions(term_id, filters \\ %{}, opts \\ []), to: NeuZeit.Catalog.Sessions
  defdelegate count_sessions(term_id, filters \\ %{}), to: NeuZeit.Catalog.Sessions
  defdelegate get_session!(id, term_id), to: NeuZeit.Catalog.Sessions
  defdelegate get_session!(id), to: NeuZeit.Catalog.Sessions

  def create_session(_attrs),
    do: {:error, {:conflict, "Edit teaching load instead of individual sessions."}}

  def update_session(_session, _attrs),
    do: {:error, {:conflict, "Edit teaching load instead of individual sessions."}}

  defdelegate change_session(session, attrs \\ %{}), to: NeuZeit.Catalog.Sessions
  defdelegate merge_candidates(term_id), to: NeuZeit.Catalog.Sessions

  def delete_session(_session),
    do: {:error, {:conflict, "Edit teaching load instead of individual sessions."}}

  defdelegate list_workload(term_id), to: NeuZeit.Catalog.Workloads, as: :list
  defdelegate save_workload(term_id, original, attrs), to: NeuZeit.Catalog.Workloads, as: :save
  defdelegate delete_workload(term_id, original), to: NeuZeit.Catalog.Workloads, as: :delete
  defdelegate error_changeset(schema, field, message), to: NeuZeit.Catalog.WriteSupport
end
