defmodule NeuZeitWeb.ReportActionsTest do
  use NeuZeitWeb.ConnCase, async: true
  import NeuZeit.Fixtures

  test "coverage uses saved teaching hours for fixed repetitions", %{conn: conn} do
    term = term_fixture()
    session = session_fixture(term: term)
    plan = plan_fixture(term: term)
    {:ok, view, _html} = live(conn, ~p"/terms/#{term}/plans/#{plan}?tab=coverage")

    assert has_element?(view, "#coverage", session.course_component.course.title)
    refute has_element?(view, "#coverage", "Not set")
    refute has_element?(view, "#coverage a", "Set teaching hours")

    refute has_element?(view, "#coverage th", "Credits")
  end

  test "overview identifies its plan and links to the unplaced sessions", %{conn: conn} do
    term = term_fixture()
    session_fixture(term: term)
    plan = plan_fixture(term: term)
    {:ok, view, _html} = live(conn, "/terms/#{term.id}?plan_id=#{plan.id}")
    assert has_element?(view, "#main-content a", plan.name)
    assert has_element?(view, "#readiness a[href='/terms/#{term.id}/plans/#{plan.id}?tab=board']")

    # The plan holds no conflicts yet, so those rows offer nothing to open.
    refute has_element?(
             view,
             "#readiness a[href='/terms/#{term.id}/plans/#{plan.id}?tab=checks']"
           )

    refute has_element?(
             view,
             "#readiness a[href='/terms/#{term.id}/plans/#{plan.id}?tab=advisories']"
           )

    refute has_element?(view, "#main-content .stat")
  end

  test "published plan offers a draft copy instead of disabled editing actions", %{conn: conn} do
    term = term_fixture()
    plan = plan_fixture(term: term, status: "active")
    {:ok, view, _html} = live(conn, "/terms/#{term.id}/plans/#{plan.id}")
    refute has_element?(view, "#solve-button")
    refute has_element?(view, "button[phx-click=undo]")
    assert has_element?(view, "button[phx-click=clone_draft]")
  end

  test "empty quality report offers a next action", %{conn: conn} do
    term = term_fixture()
    plan = plan_fixture(term: term)
    {:ok, view, _html} = live(conn, "/terms/#{term.id}/plans/#{plan.id}?tab=quality")
    assert render(view) =~ "No scheduled sessions"
    view |> element("#main-content a", "Open timetable") |> render_click()
    assert URI.decode_query(URI.parse(assert_patch(view)).query)["tab"] == "board"
  end

  test "room action opens an occupied week and clears unrelated selection", %{conn: conn} do
    term = term_fixture()
    session = session_fixture(term: term, week_mask: [2, 4])
    plan = plan_fixture(term: term)
    room = hd(session.course_component.allowed_rooms)

    placement_fixture(%{
      plan_id: plan.id,
      session_id: session.id,
      room_id: room.id,
      day: 1,
      slot: 1,
      week_mask: [2, 4],
      duration_slots: 1
    })

    {:ok, view, _html} =
      live(
        conn,
        "/terms/#{term.id}/plans/#{plan.id}?tab=quality&week=1&q=missing&session=#{session.id}"
      )

    assert has_element?(view, "#quality-cohorts")
    assert has_element?(view, "#quality-teachers")
    view |> element("#quality-rooms a", room.name) |> render_click()
    params = URI.decode_query(URI.parse(assert_patch(view)).query)
    assert params["week"] == "2"
    assert params["resource"] == room.id
    assert params["lens"] == "room"
    refute Map.has_key?(params, "q")
    refute Map.has_key?(params, "session")
  end
end
