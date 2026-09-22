defmodule NeuZeit.Curriculum do
  alias NeuZeit.Catalog.{Course, Term, Workloads, WorkloadDistribution}
  alias NeuZeit.Config
  alias NeuZeit.Repo

  def course_contact_coverage(term_id, course_id) do
    term = Repo.get!(Term, term_id)
    course = Repo.get!(Course, course_id)
    workloads = Workloads.list(term_id)

    course_coverage(
      term,
      course,
      Enum.filter(workloads, &(&1.requirement.course_component.course_id == course.id))
    )
  end

  defp course_coverage(term, course, workloads) do
    sessions = Enum.flat_map(workloads, & &1.sessions)
    minutes = WorkloadDistribution.planned_minutes(sessions, term)
    target = target_minutes(workloads, term)
    academic_hours = minutes / term.academic_hour_minutes
    required_hours = required_hours(workloads, term.academic_hour_minutes)

    scheduled_hours = minutes / 60
    delta_hours = difference(scheduled_hours, required_hours)

    required_sws =
      if required_hours,
        do: required_hours * 60 / term.academic_hour_minutes / term.weeks_count

    scheduled_sws = academic_hours / term.weeks_count

    %{
      course_id: course.id,
      term_id: term.id,
      required_hours: required_hours,
      scheduled_hours: scheduled_hours,
      delta_hours: delta_hours,
      required_sws: required_sws,
      scheduled_sws: scheduled_sws,
      missing_workload: is_nil(required_hours),
      rounded_hours: clock_hours(target),
      status: status(minutes, target)
    }
  end

  @doc """
  Returns contact-hour coverage for every course with teaching load or sessions in a term.
  """
  def term_coverage(term_id) do
    term = Repo.get!(Term, term_id)
    workloads = Workloads.list(term_id)

    workloads
    |> Enum.group_by(& &1.requirement.course_component.course_id)
    |> Enum.map(fn {_id, rows} ->
      course = hd(rows).requirement.course_component.course

      course_coverage(term, course, rows)
      |> Map.put(:code, course.code)
      |> Map.put(:title, course.title)
      |> Map.put(:translations, course.translations)
    end)
    |> Enum.sort_by(&{&1.title, &1.course_id})
  end

  @doc "Planned and dated contact hours for each course/cohort in one selected plan."
  def plan_coverage(plan_id) do
    projection = NeuZeit.Planning.project_plan(plan_id)
    policy = Config.load!(projection.term)
    workloads = Workloads.list(projection.term.id)
    sessions = Enum.flat_map(workloads, & &1.sessions)

    dated =
      projection.occurrences
      |> Enum.reject(& &1.cancelled?)
      |> Enum.group_by(& &1.session_id)
      |> Map.new(fn {id, occurrences} ->
        minutes =
          Enum.reduce(occurrences, 0, fn o, acc ->
            acc +
              Enum.reduce(
                Enum.slice(policy.grid.slots, o.slot - 1, o.duration_slots || 1),
                0,
                fn slot, sum -> sum + to_minutes(slot.end) - to_minutes(slot.start) end
              )
          end)

        {id, minutes}
      end)

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

      target = target_minutes(Enum.map(targets, &elem(&1, 0)), projection.term)

      planned_minutes =
        WorkloadDistribution.planned_minutes(Enum.map(entries, &elem(&1, 0)), projection.term)

      calendar_minutes =
        Enum.reduce(entries, 0, fn {s, _}, total -> total + Map.get(dated, s.id, 0) end)

      planned = planned_minutes / 60
      calendar = calendar_minutes / 60

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
        required_hours: required,
        rounded_hours: clock_hours(target),
        planned_hours: planned,
        calendar_hours: calendar,
        scheduled_hours: calendar,
        delta_hours: difference(calendar, required),
        planned_delta_hours: difference(planned, required),
        planned_status: if(cohort_id, do: status(planned_minutes, target), else: :unknown),
        status: if(cohort_id, do: status(calendar_minutes, target), else: :unknown),
        exceptions_applied: projection.exceptions_applied,
        missing_workload: is_nil(required),
        missing_cohort: is_nil(cohort_id)
      }
    end)
    |> Enum.sort_by(&{&1.title, &1.cohort_name || "", &1.course_id})
  end

  defp target_minutes([], _term), do: nil

  defp target_minutes(workloads, term) do
    Enum.reduce_while(workloads, 0, fn row, total ->
      case WorkloadDistribution.quantities(row.requirement, term) do
        nil ->
          {:halt, nil}

        distribution ->
          {:cont, total + distribution.meeting_count * distribution.minutes_per_meeting}
      end
    end)
  end

  defp clock_hours(nil), do: nil
  defp clock_hours(minutes), do: minutes / 60

  defp required_hours([], _academic_hour_minutes), do: nil

  defp required_hours(workloads, academic_hour_minutes) do
    workloads
    |> Enum.reduce(Decimal.new(0), fn row, total ->
      Decimal.add(total, row.requirement.contact_hours)
    end)
    |> Decimal.mult(academic_hour_minutes)
    |> Decimal.div(60)
    |> Decimal.to_float()
  end

  defp difference(_hours, nil), do: nil
  defp difference(hours, required), do: hours - required

  defp status(_minutes, nil), do: :unknown
  defp status(minutes, target) when minutes < target, do: :under
  defp status(minutes, target) when minutes > target, do: :over
  defp status(_minutes, _target), do: :ok

  defp to_minutes(time) do
    [hours, minutes] = String.split(time, ":")
    String.to_integer(hours) * 60 + String.to_integer(minutes)
  end
end
