defmodule NeuZeit.Planning.Readiness do
  @moduledoc """
  Builds a readiness checklist from term data and an optional plan.

  Rows report one of these statuses:

    * `:blocked`: a blocking condition was found.
    * `:warning`: the data needs review.
    * `:unknown`: data or an administrator decision is required.
    * `:ok`: the check found no issue.

  The checklist does not verify actual student membership or teacher availability.
  See `docs/admin-scheduling-guide.md` for the administrator workflow.
  """

  import Ecto.Query

  alias NeuZeit.Catalog
  alias NeuZeit.Planning
  alias NeuZeit.Planning.{Placement, Plan}
  alias NeuZeit.Repo

  @doc """
  Builds the term checklist. Plan-specific checks report `:unknown` when no plan is supplied.
  """
  def report(term_id, plan_id \\ nil) do
    term = Catalog.get_term!(term_id)
    sessions = Catalog.list_sessions(term_id)

    [
      term_dates(term),
      placeholder_teachers(sessions),
      teacher_availability(term, sessions),
      merge_candidates(term_id),
      aggregate_cohorts(sessions),
      week_masks(term, sessions),
      room_pools(sessions),
      slot_profiles(sessions),
      locks(plan_id),
      unplaced(sessions, plan_id),
      hard_checks(plan_id),
      advisories(plan_id)
    ]
  end

  @doc """
  Returns whether the readiness report contains no blocked rows.
  """
  def solvable?(report), do: Enum.all?(report, &(&1.status != :blocked))

  defp item(key, status, count, detail),
    do: %{key: key, status: status, count: count, detail: detail}

  # The checklist

  defp term_dates(term) do
    excluded = length(term.excluded_dates || [])

    item(:term_dates, :ok, term.weeks_count, %{
      weeks: term.weeks_count,
      excluded_dates: excluded,
      starts_on: term.starts_on,
      ends_on: term.ends_on
    })
  end

  # Short teacher names may be abbreviations that need review.
  defp placeholder_teachers(sessions) do
    suspects =
      sessions
      |> Enum.map(& &1.teacher)
      |> Enum.uniq_by(& &1.id)
      |> Enum.filter(&placeholder_name?(&1.name))

    status = if suspects == [], do: :ok, else: :warning

    item(:placeholder_teachers, status, length(suspects), %{
      teachers: Enum.map(suspects, &%{id: &1.id, name: &1.name})
    })
  end

  defp placeholder_name?(name),
    do: not String.contains?(name, " ") and String.length(name) <= 4

  # Empty availability allows any time. Ask for review without blocking the plan.
  defp teacher_availability(term, sessions) do
    teachers = sessions |> Enum.map(& &1.teacher) |> Enum.uniq_by(& &1.id)

    unconfirmed =
      Enum.filter(teachers, fn teacher ->
        Catalog.list_teacher_availability(term.id, teacher.id) == []
      end)

    status = if unconfirmed == [], do: :ok, else: :unknown

    item(:teacher_availability, status, length(unconfirmed), %{
      total: length(teachers),
      unrestricted: Enum.map(unconfirmed, &%{id: &1.id, name: &1.name})
    })
  end

  defp merge_candidates(term_id) do
    groups = Catalog.merge_candidates(term_id)
    status = if groups == [], do: :ok, else: :warning
    item(:merge_candidates, status, length(groups), %{groups: groups})
  end

  # Flag aggregate group names for review of actual student membership.
  defp aggregate_cohorts(sessions) do
    suspects =
      sessions
      |> Enum.flat_map(& &1.cohorts)
      |> Enum.uniq_by(& &1.id)
      |> Enum.filter(&String.contains?(&1.name, "("))

    status = if suspects == [], do: :ok, else: :warning

    item(:aggregate_cohorts, status, length(suspects), %{
      cohorts: Enum.map(suspects, &%{id: &1.id, name: &1.name})
    })
  end

  defp week_masks(term, sessions) do
    automatic = Enum.count(sessions, & &1.automatic_weeks)

    full =
      Enum.count(sessions, &(!&1.automatic_weeks && length(&1.week_mask) == term.weeks_count))

    partial = length(sessions) - full - automatic

    item(:week_masks, :unknown, partial, %{
      total: length(sessions),
      every_week: full,
      automatic: automatic,
      partial: partial
    })
  end

  # Suggest reviewing room pools outside the usual range of two to five.
  defp room_pools(sessions) do
    sessions = Enum.filter(sessions, &(&1.delivery_mode == :in_person))

    components =
      sessions
      |> Enum.map(& &1.course_component)
      |> Enum.uniq_by(& &1.id)

    rooms = NeuZeit.Catalog.list_rooms()

    components =
      Enum.map(
        components,
        &%{&1 | allowed_rooms: NeuZeit.Catalog.CourseComponent.room_options(&1, rooms)}
      )

    grouped = Enum.group_by(components, &pool_band(length(&1.allowed_rooms)))
    missing = Map.get(grouped, :missing, [])
    narrow = Map.get(grouped, :narrow, [])
    broad = Map.get(grouped, :broad, [])

    status =
      cond do
        missing != [] -> :blocked
        narrow == [] and broad == [] -> :ok
        true -> :warning
      end

    item(:room_pools, status, length(missing) + length(narrow) + length(broad), %{
      missing: describe_components(missing),
      narrow: describe_components(narrow),
      broad: describe_components(broad)
    })
  end

  defp pool_band(0), do: :missing
  defp pool_band(1), do: :narrow
  defp pool_band(n) when n > 5, do: :broad
  defp pool_band(_n), do: :ok

  defp describe_components(components) do
    Enum.map(components, fn component ->
      %{
        id: component.id,
        course_code: component.course.code,
        course_title: component.course.title,
        kind: component.kind,
        rooms: length(component.allowed_rooms)
      }
    end)
  end

  # A missing profile allows any time. Ask for review without treating it as an error.
  defp slot_profiles(sessions) do
    without = Enum.filter(sessions, &is_nil(&1.slot_profile_id))
    status = if without == [], do: :ok, else: :unknown

    item(:slot_profiles, status, length(without), %{
      total: length(sessions),
      unconstrained: length(without)
    })
  end

  defp locks(nil), do: item(:locks, :unknown, 0, %{})

  defp locks(plan_id) do
    count =
      Repo.one(from p in Placement, where: p.plan_id == ^plan_id and p.locked, select: count())

    item(:locks, :ok, count, %{locked: count})
  end

  defp unplaced(_sessions, nil), do: item(:unplaced, :unknown, 0, %{})

  defp unplaced(sessions, plan_id) do
    placed =
      Repo.all(from p in Placement, where: p.plan_id == ^plan_id, select: p.session_id)
      |> MapSet.new()

    missing = Enum.reject(sessions, &MapSet.member?(placed, &1.id))
    status = if missing == [], do: :ok, else: :warning

    item(:unplaced, status, length(missing), %{total: length(sessions)})
  end

  defp hard_checks(nil), do: item(:hard_checks, :unknown, 0, %{})

  defp hard_checks(plan_id) do
    errors = Planning.check_plan(plan_id)
    status = if errors == [], do: :ok, else: :blocked

    item(:hard_checks, status, length(errors), %{
      by_type: errors |> Enum.frequencies_by(& &1.type) |> Enum.sort()
    })
  end

  defp advisories(nil), do: item(:advisories, :unknown, 0, %{})

  defp advisories(plan_id) do
    found = Planning.plan_advisories(plan_id)
    status = if found == [], do: :ok, else: :warning
    item(:advisories, status, length(found), %{advisories: found})
  end

  @doc """
  The most recent draft plan for a term, which the dashboard reports against.
  """
  def default_plan(term_id) do
    Repo.one(
      from p in Plan,
        where: p.term_id == ^term_id and p.status in ["draft", "active"],
        order_by: [desc: p.status == "draft", desc: p.inserted_at],
        limit: 1
    )
  end
end
