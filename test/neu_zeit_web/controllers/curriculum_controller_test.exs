defmodule NeuZeitWeb.CurriculumControllerTest do
  use NeuZeitWeb.ConnCase, async: true

  import NeuZeit.Fixtures

  test "GET /api/terms/:term_id/courses/:course_id/coverage returns coverage", %{conn: conn} do
    term = term_fixture()
    room = room_fixture()
    course = course_fixture(credits: Decimal.new("5"))
    component = component_fixture(course: course, rooms: [room])
    session_fixture(term: term, component: component, week_mask: Enum.to_list(1..16))

    conn = get(conn, "/api/terms/#{term.id}/courses/#{course.id}/coverage")

    assert %{"data" => data} = json_response(conn, 200)
    assert data["required_hours"] == 60.0
    assert data["scheduled_hours"] == 24.0
    assert data["status"] == "under"
  end

  test "GET coverage returns 404 for a missing course", %{conn: conn} do
    term = term_fixture()
    missing = "00000000-0000-0000-0000-000000000000"

    conn = get(conn, "/api/terms/#{term.id}/courses/#{missing}/coverage")

    assert json_response(conn, 404)
  end

  test "GET coverage returns 400 for an invalid course id", %{conn: conn} do
    term = term_fixture()

    conn = get(conn, "/api/terms/#{term.id}/courses/not-a-uuid/coverage")

    assert json_response(conn, 400)
  end
end
