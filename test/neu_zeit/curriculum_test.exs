defmodule NeuZeit.CurriculumTest do
  use NeuZeit.DataCase, async: true

  import NeuZeit.Fixtures

  alias NeuZeit.Curriculum

  test "reports contact-hour coverage of a course against its credits" do
    term = term_fixture()
    room = room_fixture()
    course = course_fixture(credits: Decimal.new("5"))

    lecture = component_fixture(course: course, kind: "lecture", rooms: [room])
    seminar = component_fixture(course: course, kind: "seminar", rooms: [room])

    weeks = Enum.to_list(1..16)
    session_fixture(term: term, component: lecture, week_mask: weeks)
    session_fixture(term: term, component: seminar, week_mask: weeks)

    coverage = Curriculum.course_contact_coverage(term.id, course.id)

    # 5 credits × 30 h/credit × 0.4 contact = 60 h required (= 5 SWS over 16 weeks).
    # Two sessions × 16 weeks × 1.5 h/slot = 48 h scheduled (= 4 SWS).
    assert coverage.required_hours == 60.0
    assert coverage.scheduled_hours == 48.0
    assert coverage.delta_hours == -12.0
    assert coverage.required_sws == 5.0
    assert coverage.scheduled_sws == 4.0
    assert coverage.status == :under
  end

  test "treats a course with no scheduled sessions as fully under" do
    term = term_fixture()
    course = course_fixture(credits: Decimal.new("3"))

    coverage = Curriculum.course_contact_coverage(term.id, course.id)

    assert coverage.required_hours == 36.0
    assert coverage.scheduled_hours == 0.0
    assert coverage.scheduled_sws == 0.0
    assert coverage.status == :under
  end

  test "counts every occupied slot of a longer session" do
    term = term_fixture()
    room = room_fixture()
    course = course_fixture(credits: Decimal.new("5"))
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
    course = course_fixture(credits: Decimal.new("5"))
    component = component_fixture(course: course, rooms: [room])

    session_fixture(term: other_term, component: component, week_mask: Enum.to_list(1..16))

    coverage = Curriculum.course_contact_coverage(term.id, course.id)

    assert coverage.scheduled_hours == 0.0
  end
end
