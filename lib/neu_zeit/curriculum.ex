defmodule NeuZeit.Curriculum do
  import Ecto.Query

  alias NeuZeit.Catalog.{Course, CourseComponent, Session, Term}
  alias NeuZeit.Config
  alias NeuZeit.Repo

  def course_contact_coverage(term_id, course_id) do
    policy = Config.load!()
    ects = policy.ects

    course = Repo.get!(Course, course_id)
    term = Repo.get!(Term, term_id)

    slot_minutes = nominal_slot_minutes(policy.grid)
    slot_hours = slot_minutes / 60
    academic_hours_per_slot = slot_minutes / ects.academic_hour_minutes

    slot_occurrences = course_slot_occurrences(term_id, course_id)

    credits = Decimal.to_float(course.credits)
    required_hours = credits * ects.hours_per_credit * ects.contact_ratio
    scheduled_hours = slot_occurrences * slot_hours
    delta_hours = scheduled_hours - required_hours

    required_sws = required_hours * 60 / ects.academic_hour_minutes / term.weeks_count
    scheduled_sws = slot_occurrences * academic_hours_per_slot / term.weeks_count

    %{
      course_id: course.id,
      term_id: term.id,
      credits: course.credits,
      required_hours: round1(required_hours),
      scheduled_hours: round1(scheduled_hours),
      delta_hours: round1(delta_hours),
      required_sws: round1(required_sws),
      scheduled_sws: round1(scheduled_sws),
      status: status(delta_hours, slot_hours)
    }
  end

  defp course_slot_occurrences(term_id, course_id) do
    Session
    |> join(:inner, [s], c in CourseComponent, on: s.course_component_id == c.id)
    |> where([s, c], c.course_id == ^course_id and s.term_id == ^term_id)
    |> select([s], {s.week_mask, s.duration_slots})
    |> Repo.all()
    |> Enum.map(fn {week_mask, duration_slots} -> length(week_mask) * duration_slots end)
    |> Enum.sum()
  end

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

  defp round1(value), do: Float.round(value * 1.0, 1)
end
