defmodule NeuZeit.Curriculum do
  alias NeuZeit.Catalog.{Course, Term, Workloads}
  alias NeuZeit.Config
  alias NeuZeit.Repo

  def course_contact_coverage(term_id, course_id) do
    policy = Config.load!(term_id)

    course = Repo.get!(Course, course_id)
    term = Repo.get!(Term, term_id)

    slot_minutes = nominal_slot_minutes(policy.grid)
    slot_hours = slot_minutes / 60
    academic_hours_per_slot = slot_minutes / term.academic_hour_minutes

    slot_occurrences = course_slot_occurrences(term_id, course_id)

    workloads =
      Workloads.list(term_id)
      |> Enum.filter(&(&1.requirement.course_component.course_id == course_id))

    required_hours = required_hours(workloads, term.academic_hour_minutes)

    scheduled_hours = slot_occurrences * slot_hours
    delta_hours = difference(scheduled_hours, required_hours)

    required_sws =
      if required_hours,
        do: required_hours * 60 / term.academic_hour_minutes / term.weeks_count

    scheduled_sws = slot_occurrences * academic_hours_per_slot / term.weeks_count

    %{
      course_id: course.id,
      term_id: term.id,
      required_hours: round1(required_hours),
      scheduled_hours: round1(scheduled_hours),
      delta_hours: round1(delta_hours),
      required_sws: round1(required_sws),
      scheduled_sws: round1(scheduled_sws),
      missing_workload: is_nil(required_hours),
      status: status(delta_hours, slot_hours)
    }
  end

  @doc """
  Returns contact-hour coverage for every course with teaching load or sessions in a term.
  """
  def term_coverage(term_id) do
    Workloads.list(term_id)
    |> Enum.map(& &1.requirement.course_component.course)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(&{&1.title, &1.id})
    |> Enum.map(fn course ->
      term_id
      |> course_contact_coverage(course.id)
      |> Map.put(:code, course.code)
      |> Map.put(:title, course.title)
      |> Map.put(:translations, course.translations)
    end)
  end

  @doc "Planned and dated contact hours for each course/cohort in one selected plan."
  def plan_coverage(plan_id) do
    projection = NeuZeit.Planning.project_plan(plan_id)
    policy = Config.load!(projection.term)
    slot_hours = nominal_slot_minutes(policy.grid) / 60
    sessions = NeuZeit.Catalog.list_sessions(projection.term.id)

    dated =
      projection.occurrences
      |> Enum.reject(& &1.cancelled?)
      |> Enum.group_by(& &1.session_id)
      |> Map.new(fn {id, occurrences} ->
        hours =
          Enum.reduce(occurrences, 0.0, fn o, acc ->
            acc +
              Enum.reduce(
                Enum.slice(policy.grid.slots, o.slot - 1, o.duration_slots || 1),
                0.0,
                fn slot, sum -> sum + (to_minutes(slot.end) - to_minutes(slot.start)) / 60 end
              )
          end)

        {id, hours}
      end)

    workloads = Workloads.list(projection.term.id)

    required_groups =
      workloads
      |> Enum.flat_map(fn row ->
        Enum.map(
          row.requirement.cohorts,
          &{{row.requirement.course_component.course_id, &1.id}, {row, &1}}
        )
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    session_groups =
      sessions
      |> Enum.flat_map(fn session ->
        cohorts = if session.cohorts == [], do: [%{id: nil, name: nil}], else: session.cohorts
        Enum.map(cohorts, &{{session.course_component.course_id, &1.id}, {session, &1}})
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    (Map.keys(session_groups) ++ Map.keys(required_groups))
    |> Enum.uniq()
    |> Enum.map(fn {course_id, cohort_id} = key ->
      entries = Map.get(session_groups, key, [])
      targets = Map.get(required_groups, key, [])

      {source, cohort} =
        case entries do
          [first | _] ->
            first

          [] ->
            {row, cohort} = hd(targets)
            {row.requirement, cohort}
        end

      course = source.course_component.course

      required =
        required_hours(Enum.map(targets, &elem(&1, 0)), projection.term.academic_hour_minutes)

      planned =
        Enum.reduce(entries, 0.0, fn {s, _}, total ->
          total +
            if(s.automatic_weeks, do: 1, else: length(s.week_mask)) * s.duration_slots *
              slot_hours
        end)

      calendar =
        Enum.reduce(entries, 0.0, fn {s, _}, total -> total + Map.get(dated, s.id, 0.0) end)

      %{
        course_id: course_id,
        cohort_id: cohort_id,
        cohort_name: cohort.name,
        term_id: projection.term.id,
        plan_id: plan_id,
        plan_status: projection.plan.status,
        code: course.code,
        title: course.title,
        translations: course.translations,
        required_hours: round1(required),
        planned_hours: round1(planned),
        calendar_hours: round1(calendar),
        scheduled_hours: round1(calendar),
        delta_hours: round1(difference(calendar, required)),
        planned_delta_hours: round1(difference(planned, required)),
        planned_status:
          if(cohort_id, do: status(difference(planned, required), slot_hours), else: :unknown),
        status:
          if(cohort_id, do: status(difference(calendar, required), slot_hours), else: :unknown),
        exceptions_applied: projection.exceptions_applied,
        missing_workload: is_nil(required),
        missing_cohort: is_nil(cohort_id)
      }
    end)
    |> Enum.sort_by(&{&1.title, &1.cohort_name || "", &1.course_id})
  end

  defp course_slot_occurrences(term_id, course_id) do
    NeuZeit.Catalog.list_sessions(term_id)
    |> Enum.filter(&(&1.course_component.course_id == course_id))
    |> Enum.map(fn session ->
      if(session.automatic_weeks, do: 1, else: length(session.week_mask)) * session.duration_slots
    end)
    |> Enum.sum()
  end

  defp required_hours([], _academic_hour_minutes), do: nil

  defp required_hours(workloads, academic_hour_minutes) do
    Enum.sum(
      Enum.map(workloads, fn row ->
        Decimal.to_float(row.requirement.contact_hours) * academic_hour_minutes / 60
      end)
    )
  end

  defp difference(_hours, nil), do: nil
  defp difference(hours, required), do: hours - required

  defp status(nil, _tolerance), do: :unknown
  defp status(delta, tolerance) when delta < -tolerance, do: :under
  defp status(delta, tolerance) when delta > tolerance, do: :over
  defp status(_delta, _tolerance), do: :ok

  defp nominal_slot_minutes(grid) do
    durations =
      Enum.map(grid.slots, fn slot -> to_minutes(slot[:end]) - to_minutes(slot[:start]) end)

    Enum.sum(durations) / length(durations)
  end

  defp to_minutes(time) do
    [hours, minutes] = String.split(time, ":")
    String.to_integer(hours) * 60 + String.to_integer(minutes)
  end

  defp round1(nil), do: nil
  defp round1(value), do: Float.round(value * 1.0, 1)
end
