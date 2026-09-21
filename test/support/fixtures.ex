defmodule NeuZeit.Fixtures do
  alias NeuZeit.Catalog
  alias NeuZeit.Planning
  alias NeuZeit.Planning.Plan
  alias NeuZeit.Repo

  def term_fixture(attrs \\ %{}) do
    {:ok, term} =
      attrs
      |> Enum.into(%{
        name: "Autumn 2026",
        starts_on: ~D[2026-08-31],
        ends_on: ~D[2026-12-19],
        excluded_dates: []
      })
      |> Catalog.create_term()

    term
  end

  def building_fixture(attrs \\ %{}) do
    {:ok, building} = attrs |> Enum.into(%{name: unique("Main")}) |> Catalog.create_building()
    building
  end

  def room_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    building = Map.get(attrs, :building) || building_fixture()

    attrs =
      attrs
      |> Map.drop([:building])
      |> Enum.into(%{building_id: building.id, name: unique("A-204")})

    {:ok, room} = Catalog.create_room(attrs)
    room
  end

  def course_fixture(attrs \\ %{}) do
    {:ok, course} =
      attrs
      |> Enum.into(%{title: "Algorithms"})
      |> Catalog.create_course()

    course
  end

  def component_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    course = Map.get(attrs, :course) || course_fixture()
    rooms = Map.get(attrs, :rooms) || [room_fixture()]

    attrs =
      attrs
      |> Map.drop([:course, :rooms])
      |> Enum.into(%{
        course_id: course.id,
        kind: "lecture",
        allowed_room_ids: Enum.map(rooms, & &1.id)
      })

    {:ok, component} = Catalog.create_course_component(attrs)
    Catalog.get_course_component!(component.id)
  end

  def teacher_fixture(attrs \\ %{}) do
    {:ok, teacher} = attrs |> Enum.into(%{name: unique("Teacher")}) |> Catalog.create_teacher()
    teacher
  end

  def teacher_availability_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    term = Map.get(attrs, :term) || term_fixture()
    teacher = Map.get(attrs, :teacher) || teacher_fixture()
    cells = Map.get(attrs, :cells) || [%{day: 6, slot: 1}]

    {:ok, availability} =
      Catalog.replace_teacher_availability(term.id, teacher.id, cells)

    availability
  end

  def cohort_fixture(attrs \\ %{}) do
    {:ok, cohort} = attrs |> Enum.into(%{name: unique("CS-2026")}) |> Catalog.create_cohort()
    cohort
  end

  def slot_profile_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    term = Map.get(attrs, :term) || term_fixture()

    attrs =
      attrs
      |> Map.drop([:term])
      |> Enum.into(%{
        term_id: term.id,
        name: unique("Profile"),
        cells: [%{day: 1, slot: 1}]
      })

    {:ok, profile} = Catalog.create_slot_profile(attrs)
    profile
  end

  def session_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    term = Map.get(attrs, :term) || term_fixture()
    component = Map.get(attrs, :component) || component_fixture()
    teacher = Map.get(attrs, :teacher) || teacher_fixture()
    cohorts = Map.get(attrs, :cohorts) || [cohort_fixture()]

    attrs =
      attrs
      |> Map.drop([:term, :component, :teacher, :cohorts])
      |> Enum.into(%{
        term_id: term.id,
        course_component_id: component.id,
        teacher_id: teacher.id,
        week_mask: [1, 2],
        cohort_ids: Enum.map(cohorts, & &1.id)
      })

    {:ok, session} = create_session(attrs)
    Catalog.get_session!(session.id)
  end

  # Fixtures can represent existing fixed repetitions. All production creation uses Workloads.save.
  def create_session(attrs) do
    attrs =
      Map.new(attrs, fn {key, value} ->
        {if(is_binary(key), do: String.to_existing_atom(key), else: key), value}
      end)

    term = Catalog.get_term!(attrs.term_id)

    fields =
      Map.merge(
        %{
          duration_slots: 1,
          week_mask: [],
          automatic_weeks: false,
          delivery_mode: :in_person,
          sequence_group: nil,
          slot_profile_id: nil
        },
        attrs
      )
      |> Map.update!(:delivery_mode, fn
        "online" -> :online
        "in_person" -> :in_person
        mode -> mode
      end)

    repeats = if fields.automatic_weeks, do: 1, else: max(length(fields.week_mask), 1)
    duration = if is_integer(fields.duration_slots), do: max(fields.duration_slots, 1), else: 1
    slot = hd(term.grid.slots)

    slot_minutes =
      NeuZeit.Scheduling.Grid.minutes(slot.end) - NeuZeit.Scheduling.Grid.minutes(slot.start)

    hours = Decimal.from_float(duration * repeats * slot_minutes / term.academic_hour_minutes)

    Repo.transaction(fn ->
      requirement =
        struct(
          NeuZeit.Catalog.Workload,
          Map.take(fields, [
            :term_id,
            :course_component_id,
            :teacher_id,
            :slot_profile_id,
            :week_mask,
            :duration_slots,
            :automatic_weeks,
            :delivery_mode,
            :sequence_group
          ])
        )
        |> Ecto.Changeset.change(contact_hours: hours)
        |> Repo.insert!()

      case NeuZeit.Catalog.Sessions.create_generated_session(requirement.id, attrs) do
        {:ok, session} ->
          for id <- Enum.uniq(Map.get(attrs, :cohort_ids, [])) do
            Repo.insert!(%NeuZeit.Catalog.WorkloadCohort{
              workload_id: requirement.id,
              cohort_id: id
            })
          end

          session

        {:error, error} ->
          Repo.rollback(error)
      end
    end)
  end

  def plan_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    term = Map.get(attrs, :term) || term_fixture()

    attrs =
      attrs
      |> Map.drop([:term])
      |> Enum.into(%{term_id: term.id, name: unique("Draft")})

    {:ok, plan} =
      if Map.has_key?(attrs, :status) or Map.has_key?(attrs, "status") do
        %Plan{} |> Plan.changeset(attrs) |> Repo.insert()
      else
        Planning.create_plan(attrs)
      end

    plan
  end

  def placement_fixture(attrs \\ %{}) do
    {:ok, placement} = Planning.create_placement(Map.new(attrs))
    Planning.get_placement!(placement.id)
  end

  def unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
