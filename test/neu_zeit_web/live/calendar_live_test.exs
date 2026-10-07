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

    {:ok, course} = Catalog.create_course(%{"code" => "INF110", "title" => "Programming"})

    {:ok, component} =
      Catalog.create_course_component(%{
        "course_id" => course.id,
        "kind" => "lecture",
        "allowed_room_ids" => [room.id]
      })

    {:ok, session} =
      NeuZeit.Fixtures.create_session(%{
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
    {:ok, live, _html} = live(conn, ~p"/terms/#{term}/calendar?week=1")

    # Week 1 Monday is 2026-09-07.
    assert has_element?(live, "#calendar-day-2026-09-07", "Programming")
    assert has_element?(live, "#calendar-day-2026-09-07", "Anna Weber")
  end

  test "says a draft carries no one-off changes", %{conn: conn, term: term} do
    {:ok, _live, html} = live(conn, ~p"/terms/#{term}/calendar")
    assert html =~ "One-off changes are shown only for the active plan."
  end

  describe "selecting a dated session" do
    test "opens a panel with its details and keeps the selection in the URL",
         %{conn: conn} = ctx do
      {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/calendar?week=1")
      refute has_element?(live, "#occurrence-panel")

      live
      |> element(~s{#calendar-day-2026-09-07 button[data-session-id="#{ctx.session.id}"]})
      |> render_click()

      path = assert_patch(live)

      assert URI.decode_query(URI.parse(path).query)["occurrence"] ==
               "#{ctx.session.id}:2026-09-07"

      assert has_element?(live, "#occurrence-panel", "Programming")
      assert has_element?(live, "#occurrence-panel", "Anna Weber")
      assert has_element?(live, "#occurrence-panel", "WI-1")
      assert has_element?(live, "#occurrence-panel", "101")

      # A draft allows no one-off changes, so the panel only explains that.
      refute has_element?(live, "#occurrence-panel button", "Cancel dated session")

      assert has_element?(
               live,
               "#occurrence-panel",
               "One-off changes apply only to the active plan."
             )

      live |> element("#occurrence-panel button[aria-label='Close']") |> render_click()
      refute has_element?(live, "#occurrence-panel")
    end

    test "cancelling from the panel records the change and stays on the calendar",
         %{conn: conn} = ctx do
      {:ok, _} = Planning.publish_plan(ctx.plan.id)
      {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/calendar?week=2")

      live
      |> element(~s{#calendar-day-2026-09-14 button[data-session-id="#{ctx.session.id}"]})
      |> render_click()

      assert_patch(live)
      refute has_element?(live, "#change-dialog")
      live |> element("#occurrence-panel button", "Cancel dated session") |> render_click()
      assert has_element?(live, "#change-dialog #exception-form")

      assert has_element?(
               live,
               ~s{#change-dialog input[name="schedule_exception[occurrence_date]"][value="2026-09-14"]}
             )

      html =
        live
        |> form("#exception-form",
          schedule_exception: %{reason: "Teacher ill", created_by: "Admin"}
        )
        |> render_submit()

      assert [exception] = Planning.list_schedule_exceptions(ctx.term.id)
      assert exception.kind == "cancel"
      assert exception.occurrence_date == ~D[2026-09-14]

      path = assert_patch(live)
      assert URI.parse(path).path == "/terms/#{ctx.term.id}/calendar"
      assert html =~ "Change saved." or render(live) =~ "Change saved."
      refute has_element?(live, "#change-dialog")
      assert has_element?(live, "#calendar-day-2026-09-14 [data-cancelled='true']", "Programming")
      assert has_element?(live, "#selected-change", "Cancelled")
      assert has_element?(live, "#selected-change", "Teacher ill")
      assert has_element?(live, "#occurrence-panel button", "Revert change")
      refute has_element?(live, "#occurrence-panel button", "Cancel dated session")
    end

    test "escape closes the change dialog without saving", %{conn: conn} = ctx do
      {:ok, _} = Planning.publish_plan(ctx.plan.id)

      {:ok, live, _html} =
        live(
          conn,
          ~p"/terms/#{ctx.term}/calendar?#{%{week: 2, occurrence: "#{ctx.session.id}:2026-09-14"}}"
        )

      live |> element("#occurrence-panel button", "Replace teacher") |> render_click()
      assert has_element?(live, "#change-dialog")
      render_hook(live, "close_change", %{})
      refute has_element?(live, "#change-dialog")
      assert has_element?(live, "#occurrence-panel")
      assert Planning.list_schedule_exceptions(ctx.term.id) == []
    end

    test "reverting from the panel keeps the record", %{conn: conn} = ctx do
      {:ok, _} = Planning.publish_plan(ctx.plan.id)

      {:ok, exception} =
        Planning.create_schedule_exception(%{
          session_id: ctx.session.id,
          kind: "cancel",
          occurrence_date: ~D[2026-09-14],
          reason: "Teacher ill",
          created_by: "Admin"
        })

      {:ok, live, _html} =
        live(
          conn,
          ~p"/terms/#{ctx.term}/calendar?#{%{week: 2, occurrence: "#{ctx.session.id}:2026-09-14"}}"
        )

      live |> element("#occurrence-panel button", "Revert change") |> render_click()
      live |> element("#confirm-modal button", "Revert change") |> render_click()

      assert Planning.get_schedule_exception!(exception.id).status == "reverted"

      assert has_element?(
               live,
               "#calendar-day-2026-09-14 [data-cancelled='false']",
               "Programming"
             )

      refute has_element?(live, "#selected-change")
    end
  end

  describe "the default week" do
    defp today_at_institution do
      case DateTime.now(NeuZeit.Settings.snapshot().timezone) do
        {:ok, now} -> DateTime.to_date(now)
        {:error, _} -> Date.utc_today()
      end
    end

    defp term_with_plan(starts_on, ends_on) do
      {:ok, term} =
        Catalog.create_term(%{
          "name" => "Around today",
          "starts_on" => Date.to_iso8601(starts_on),
          "ends_on" => Date.to_iso8601(ends_on)
        })

      {:ok, _plan} = Planning.create_plan(%{"term_id" => term.id, "name" => "Entwurf"})
      term
    end

    test "is the week with today's date when the term is running", %{conn: conn} do
      today = today_at_institution()
      term = term_with_plan(Date.add(today, -21), Date.add(today, 42))
      expected = NeuZeit.Scheduling.TermDates.week(term, today)

      {:ok, live, _html} = live(conn, ~p"/terms/#{term}/calendar")
      assert has_element?(live, "#calendar-day-#{Date.to_iso8601(today)}")
      assert render(live) =~ "Week #{expected} of #{term.weeks_count}"

      # An explicit week still wins.
      {:ok, live, _html} = live(conn, ~p"/terms/#{term}/calendar?week=1")
      assert render(live) =~ "Week 1 of #{term.weeks_count}"
    end

    test "is the last week once the term is over", %{conn: conn} do
      today = today_at_institution()
      term = term_with_plan(Date.add(today, -70), Date.add(today, -7))

      {:ok, live, _html} = live(conn, ~p"/terms/#{term}/calendar")
      assert render(live) =~ "Week #{term.weeks_count} of #{term.weeks_count}"
    end

    test "is the first week before the term starts", %{conn: conn} do
      today = today_at_institution()
      term = term_with_plan(Date.add(today, 30), Date.add(today, 90))

      {:ok, live, _html} = live(conn, ~p"/terms/#{term}/calendar")
      assert render(live) =~ "Week 1 of #{term.weeks_count}"
    end
  end

  test "a non-teaching day shows as such and holds nothing", %{conn: conn, term: term} do
    {:ok, live, _html} = live(conn, ~p"/terms/#{term}/calendar")

    live |> element(~s{button[phx-value-week="3"]}, "With non-teaching dates") |> render_click()

    # The third Monday is non-teaching, so the calendar omits its meeting.
    assert has_element?(live, "#calendar-day-2026-09-21", "Non-teaching date")
    refute has_element?(live, "#calendar-day-2026-09-21", "Programming")
  end

  test "the week before the holiday still holds the class", %{conn: conn, term: term} do
    {:ok, live, _html} = live(conn, ~p"/terms/#{term}/calendar?week=1")

    live |> element(~s{button[aria-label="Next week"][phx-value-week="2"]}) |> render_click()
    assert has_element?(live, "#calendar-day-2026-09-14", "Programming")
  end

  test "scoping to a cohort keeps only its classes", %{conn: conn, term: term, cohort: cohort} do
    {:ok, other} = Catalog.create_cohort(%{"name" => "IT-1"})

    {:ok, live, _html} = live(conn, ~p"/terms/#{term}/calendar?week=1")
    assert has_element?(live, "#calendar-day-2026-09-07", "Programming")

    live |> element("form[phx-change='select_scope']") |> render_change(%{"scope" => other.id})
    refute has_element?(live, "#calendar-day-2026-09-07", "Programming")

    live |> element("form[phx-change='select_scope']") |> render_change(%{"scope" => cohort.id})
    assert has_element?(live, "#calendar-day-2026-09-07", "Programming")
  end

  describe "dragging an occurrence" do
    test "opens a pre-filled move dialog for a published plan", %{conn: conn} = ctx do
      {:ok, _} = Planning.publish_plan(ctx.plan.id)
      {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/calendar?week=1")

      render_hook(live, "move_occurrence", %{
        "session-id" => ctx.session.id,
        "from" => "2026-09-07",
        "to" => "2026-09-08"
      })

      # Dragging opens the change form in place; saving requires a reason and author.
      assert has_element?(live, "#change-dialog #exception-form")
      form = "#change-dialog #exception-form "

      assert has_element?(
               live,
               form <> ~s{select[name="schedule_exception[kind]"] option[selected][value="move"]}
             )

      assert has_element?(
               live,
               form <> ~s{input[name="schedule_exception[session_id]"][value="#{ctx.session.id}"]}
             )

      assert has_element?(
               live,
               form <> ~s{input[name="schedule_exception[occurrence_date]"][value="2026-09-07"]}
             )

      assert has_element?(
               live,
               form <> ~s{input[name="schedule_exception[new_date]"][value="2026-09-08"]}
             )

      assert has_element?(
               live,
               form <> ~s{select[name="schedule_exception[new_slot]"] option[selected][value="1"]}
             )

      assert Planning.list_schedule_exceptions(ctx.term.id) == []

      live
      |> form("#exception-form",
        schedule_exception: %{reason: "Room needed", created_by: "Admin"}
      )
      |> render_submit()

      assert [exception] = Planning.list_schedule_exceptions(ctx.term.id)
      assert exception.kind == "move"
      assert exception.new_date == ~D[2026-09-08]
      assert_patch(live)
      assert has_element?(live, "#calendar-day-2026-09-08", "Moved")
      assert has_element?(live, "#selected-change", "Room needed")
    end

    test "refuses on a draft, because one-off changes apply only to the active plan",
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
