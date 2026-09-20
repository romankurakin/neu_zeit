defmodule NeuZeit.CurriculumTest do
  use NeuZeit.DataCase, async: true

  import NeuZeit.Fixtures

  alias NeuZeit.{Catalog, Curriculum}

  test "compares saved teaching hours with generated sessions even after sessions are deleted" do
    term = term_fixture()
    room = room_fixture()
    course = course_fixture()

    lecture = component_fixture(course: course, kind: "lecture", rooms: [room])
    seminar = component_fixture(course: course, kind: "seminar", rooms: [room])

    save_hours(term, lecture, "40")
    save_hours(term, seminar, "40")

    for session <- Enum.take(Catalog.list_sessions(term.id), 8) do
      assert {:ok, _} = NeuZeit.Catalog.Sessions.delete_generated_session(session)
    end

    coverage = Curriculum.course_contact_coverage(term.id, course.id)

    # 80 academic hours require 60 clock hours. The remaining 32 meetings cover 48.
    assert coverage.required_hours == 60.0
    assert coverage.scheduled_hours == 48.0
    assert coverage.delta_hours == -12.0
    assert coverage.required_sws == 5.0
    assert coverage.scheduled_sws == 4.0
    assert coverage.status == :under
  end

  test "does not invent a target for a course without teaching load" do
    term = term_fixture()
    course = course_fixture()

    coverage = Curriculum.course_contact_coverage(term.id, course.id)

    assert coverage.required_hours == nil
    assert coverage.required_sws == nil
    assert coverage.delta_hours == nil
    assert coverage.missing_workload
    assert coverage.scheduled_hours == 0.0
    assert coverage.scheduled_sws == 0.0
    assert coverage.status == :unknown
  end

  test "counts every occupied slot of a longer session" do
    term = term_fixture()
    room = room_fixture()
    course = course_fixture()
    component = component_fixture(course: course, rooms: [room])

    session_fixture(
      term: term,
      component: component,
      week_mask: Enum.to_list(1..16),
      duration_slots: 2
    )

    coverage = Curriculum.course_contact_coverage(term.id, course.id)
    assert coverage.scheduled_hours == 48.0
    assert coverage.scheduled_sws == 4.0
  end

  test "ignores sessions belonging to other terms" do
    term = term_fixture()
    other_term = term_fixture()
    room = room_fixture()
    course = course_fixture()
    component = component_fixture(course: course, rooms: [room])

    session_fixture(term: other_term, component: component, week_mask: Enum.to_list(1..16))

    coverage = Curriculum.course_contact_coverage(term.id, course.id)

    assert coverage.scheduled_hours == 0.0
  end

  test "counts the saved requirement for fixed repetitions" do
    term = term_fixture()
    session = session_fixture(term: term, week_mask: [1, 2])
    coverage = Curriculum.course_contact_coverage(term.id, session.course_component.course_id)

    assert coverage.scheduled_hours == 3.0
    assert coverage.required_hours == 3.0
    assert coverage.delta_hours == 0.0
    assert coverage.status == :ok
  end

  test "combines saved fixed and automatic teaching load" do
    term = term_fixture()
    component = component_fixture()
    save_hours(term, component, "4")
    session_fixture(term: term, component: component)

    coverage = Curriculum.course_contact_coverage(term.id, component.course_id)
    assert coverage.scheduled_hours == 6.0
    assert coverage.required_hours == 6.0
    assert coverage.status == :ok
  end

  defp save_hours(term, component, hours) do
    session =
      session_fixture(
        term: term,
        component: component,
        automatic_weeks: true,
        week_mask: Enum.to_list(1..term.weeks_count)
      )

    row = Enum.find(Catalog.list_workload(term.id), &(&1.id == session.workload_id))

    assert {:ok, :saved} =
             Catalog.save_workload(term.id, row, %{contact_hours: hours})
  end
end
