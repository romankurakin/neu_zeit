defmodule NeuZeitWeb.CalendarLiveTest do
  use NeuZeitWeb.ConnCase, async: true

  alias NeuZeit.{Catalog, Planning}

  setup do
    {:ok, term} =
      Catalog.create_term(%{
        "name" => "Wintersemester 2026/27",
        "starts_on" => "2026-09-07",
        "ends_on" => "2026-12-20",
        # A Monday in week 3.
        "excluded_dates" => [~D[2026-09-21]]
      })

    {:ok, building} = Catalog.create_building(%{"name" => "Hauptgebäude"})
    {:ok, room} = Catalog.create_room(%{"building_id" => building.id, "name" => "101"})
    {:ok, plan} = Planning.create_plan(%{"term_id" => term.id, "name" => "Entwurf 1"})
    {:ok, cohort} = Catalog.create_cohort(%{"name" => "WI-1"})
    {:ok, teacher} = Catalog.create_teacher(%{"name" => "Anna Weber"})

    {:ok, course} = Catalog.create_course(%{"code" => "INF110", "title" => "P", "credits" => 8})

    {:ok, component} =
      Catalog.create_course_component(%{
        "course_id" => course.id,
        "kind" => "lecture",
        "allowed_room_ids" => [room.id]
      })

    {:ok, session} =
      Catalog.create_session(%{
        "term_id" => term.id,
        "course_component_id" => component.id,
        "teacher_id" => teacher.id,
        # Mondays in weeks 1 to 4.
        "week_mask" => [1, 2, 3, 4],
        "duration_slots" => 1,
        "cohort_ids" => [cohort.id]
      })

    {:ok, _placement} =
      Planning.create_placement(%{
        "plan_id" => plan.id,
        "session_id" => session.id,
        "room_id" => room.id,
        "day" => 1,
        "slot" => 1
      })

    %{term: term, plan: plan, session: session, cohort: cohort, teacher: teacher}
  end

  test "projects a draft plan onto real dates", %{conn: conn, term: term} do
    {:ok, live, _html} = live(conn, ~p"/terms/#{term}/calendar")

    # Week 1 Monday is 2026-09-07.
    assert has_element?(live, "#calendar-day-2026-09-07", "INF110")
    assert has_element?(live, "#calendar-day-2026-09-07", "Anna Weber")
  end

  test "says a draft carries no one-off changes", %{conn: conn, term: term} do
    {:ok, _live, html} = live(conn, ~p"/terms/#{term}/calendar")
    assert html =~ "One-off changes are shown only for the published plan."
  end

  test "a non-teaching day shows as such and holds nothing", %{conn: conn, term: term} do
    {:ok, live, _html} = live(conn, ~p"/terms/#{term}/calendar")

    live |> element(~s{button[phx-value-week="3"]}, "With non-teaching dates") |> render_click()

    # The third Monday is non-teaching, so the calendar omits its meeting.
    assert has_element?(live, "#calendar-day-2026-09-21", "Non-teaching date")
    refute has_element?(live, "#calendar-day-2026-09-21", "INF110")
  end

  test "the week before the holiday still holds the class", %{conn: conn, term: term} do
    {:ok, live, _html} = live(conn, ~p"/terms/#{term}/calendar")

    live |> element(~s{button[aria-label="Next week"][phx-value-week="2"]}) |> render_click()
    assert has_element?(live, "#calendar-day-2026-09-14", "INF110")
  end

  test "scoping to a cohort keeps only its classes", %{conn: conn, term: term, cohort: cohort} do
    {:ok, other} = Catalog.create_cohort(%{"name" => "IT-1"})

    {:ok, live, _html} = live(conn, ~p"/terms/#{term}/calendar")
    assert has_element?(live, "#calendar-day-2026-09-07", "INF110")

    live |> element("form[phx-change='select_scope']") |> render_change(%{"scope" => other.id})
    refute has_element?(live, "#calendar-day-2026-09-07", "INF110")

    live |> element("form[phx-change='select_scope']") |> render_change(%{"scope" => cohort.id})
    assert has_element?(live, "#calendar-day-2026-09-07", "INF110")
  end

  describe "dragging an occurrence" do
    test "opens a pre-filled move for a published plan", %{conn: conn} = ctx do
      {:ok, _} = Planning.publish_plan(ctx.plan.id)
      {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/calendar")

      render_hook(live, "move_occurrence", %{
        "session-id" => ctx.session.id,
        "from" => "2026-09-07",
        "to" => "2026-09-08"
      })

      # Dragging opens the change form; saving requires a reason and author.
      {path, _flash} = assert_redirect(live)
      uri = URI.parse(path)
      assert uri.path == "/terms/#{ctx.term.id}/exceptions/new"
      params = URI.decode_query(uri.query)
      assert params["kind"] == "move"
      assert params["date"] == "2026-09-07"
      assert params["new_date"] == "2026-09-08"
      assert params["new_slot"] == "1"
      assert params["session_id"] == ctx.session.id
      assert params["return_to"] =~ "/calendar?"

      assert Planning.list_schedule_exceptions(ctx.term.id) == []
    end

    test "refuses on a draft, because one-off changes apply to the published timetable",
         %{conn: conn} = ctx do
      {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/calendar")

      html =
        render_hook(live, "move_occurrence", %{
          "session-id" => ctx.session.id,
          "from" => "2026-09-07",
          "to" => "2026-09-08"
        })

      assert html =~ "Publish this plan first"
    end
  end

  test "offers nothing to project when the term has no plan", %{conn: conn} do
    {:ok, empty} =
      Catalog.create_term(%{
        "name" => "Sommer 2027",
        "starts_on" => "2027-02-01",
        "ends_on" => "2027-05-30"
      })

    {:ok, live, _html} = live(conn, ~p"/terms/#{empty}/calendar")
    assert has_element?(live, "h1", "Calendar")
    assert render(live) =~ "No timetable yet"
  end
end
