defmodule NeuZeitWeb.TermLiveTest do
  use NeuZeitWeb.ConnCase, async: true

  alias NeuZeit.Catalog

  defp create_term(attrs \\ %{}) do
    {:ok, term} =
      Catalog.create_term(
        Map.merge(
          %{
            "name" => "Wintersemester 2026/27",
            "starts_on" => "2026-09-07",
            "ends_on" => "2026-12-20"
          },
          attrs
        )
      )

    term
  end

  describe "index" do
    test "/ sends the administrator to the terms list", %{conn: conn} do
      assert redirected_to(get(conn, ~p"/")) == ~p"/terms"
    end

    test "offers to create the first term when there are none", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/terms")

      assert has_element?(live, "a", "Create the first term")
      refute has_element?(live, "#terms")
    end

    test "lists terms with their derived week count", %{conn: conn} do
      term = create_term()
      {:ok, live, _html} = live(conn, ~p"/terms")

      assert has_element?(live, "#term-#{term.id}", "Wintersemester 2026/27")
      # 2026-09-07 to 2026-12-20 is 15 teaching weeks.
      assert has_element?(live, "#term-#{term.id}", "15")
    end
  end

  describe "creating" do
    test "a valid term lands on its overview", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/terms/new")

      {:ok, _show, html} =
        live
        |> form("#term-form",
          term: %{name: "Sommer 2027", starts_on: "2027-02-01", ends_on: "2027-05-30"}
        )
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "Sommer 2027"
      assert html =~ "Created Sommer 2027."
    end

    test "a start date that is not a Monday is refused inline", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/terms/new")

      # 2027-02-02 is a Tuesday. The domain requires terms to start on a Monday
      # because week numbering depends on it.
      html =
        live
        |> form("#term-form",
          term: %{name: "Bad", starts_on: "2027-02-02", ends_on: "2027-05-30"}
        )
        |> render_submit()

      assert html =~ "Choose a Monday."
      assert has_element?(live, "#term-form")
    end
  end

  describe "overview" do
    test "shows a row per teaching week", %{conn: conn} do
      term = create_term()
      {:ok, live, html} = live(conn, ~p"/terms/#{term}/settings")

      assert html =~ "Teaching calendar"
      # First and last dates of the 15-week span.
      assert has_element?(live, ~s{button[phx-value-date="2026-09-07"]})
      assert has_element?(live, ~s{button[phx-value-date="2026-12-19"]})
    end

    test "clicking a date excludes it, and clicking again restores it", %{conn: conn} do
      term = create_term()
      {:ok, live, _html} = live(conn, ~p"/terms/#{term}/settings")

      live |> element(~s{button[phx-value-date="2026-09-09"]}) |> render_click()
      assert Catalog.get_term!(term.id).excluded_dates == [~D[2026-09-09]]

      live |> element(~s{button[phx-value-date="2026-09-09"]}) |> render_click()
      assert Catalog.get_term!(term.id).excluded_dates == []
    end

    test "switching term navigates to the other term", %{conn: conn} do
      term = create_term()

      other =
        create_term(%{
          "name" => "Sommer 2027",
          "starts_on" => "2027-02-01",
          "ends_on" => "2027-05-30"
        })

      {:ok, live, _html} = live(conn, ~p"/terms/#{term}")

      live
      |> element("#term-switcher-form")
      |> render_change(%{"term_id" => other.id})

      assert_redirect(live, ~p"/terms/#{other.id}")
    end
  end

  describe "the readiness dashboard" do
    test "an empty term offers setup instead of a vacuously successful checklist", %{conn: conn} do
      term = create_term()
      {:ok, live, _html} = live(conn, ~p"/terms/#{term}")
      refute has_element?(live, "#readiness")
      assert has_element?(live, ~s{a[href="/terms/#{term.id}/workload/new"]}, "Add teaching load")

      assert has_element?(
               live,
               "p",
               "Set the teaching load and constraints, then generate a timetable."
             )
    end

    test "reports every checklist item", %{conn: conn} do
      term = create_term()
      NeuZeit.Fixtures.session_fixture(term: term)
      {:ok, live, _html} = live(conn, ~p"/terms/#{term}")

      assert has_element?(live, "#readiness")
      # One row per readiness check.
      assert has_element?(live, "#readiness", "Teacher names")
      assert has_element?(live, "#readiness", "Allowed rooms")
      assert has_element?(live, "#readiness", "Possible group overlaps")
    end

    test "names the offending records rather than only counting them", %{conn: conn} do
      term = create_term()

      {:ok, building} = Catalog.create_building(%{"name" => "Hauptgebäude"})
      {:ok, room} = Catalog.create_room(%{"building_id" => building.id, "name" => "101"})
      {:ok, course} = Catalog.create_course(%{"code" => "INF110", "title" => "P"})

      {:ok, component} =
        Catalog.create_course_component(%{
          "course_id" => course.id,
          "kind" => "lecture",
          "allowed_room_ids" => [room.id]
        })

      {:ok, placeholder} = Catalog.create_teacher(%{"name" => "Lch"})
      {:ok, cohort} = Catalog.create_cohort(%{"name" => "WI-1"})

      {:ok, _session} =
        NeuZeit.Fixtures.create_session(%{
          "term_id" => term.id,
          "course_component_id" => component.id,
          "teacher_id" => placeholder.id,
          "week_mask" => [1, 2, 3],
          "duration_slots" => 1,
          "cohort_ids" => [cohort.id]
        })

      {:ok, live, _html} = live(conn, ~p"/terms/#{term}")

      assert has_element?(live, "#readiness", "Abbreviated names: Lch")
      assert has_element?(live, "#readiness", "with a single room")
    end

    test "each row links to the screen that settles it", %{conn: conn} do
      term = create_term()
      NeuZeit.Fixtures.session_fixture(term: term)
      {:ok, live, _html} = live(conn, ~p"/terms/#{term}")

      assert has_element?(
               live,
               ~s{#readiness a[href="#{NeuZeitWeb.Nav.with_return("/courses", "/terms/#{term.id}")}"]}
             )

      assert has_element?(live, ~s{#readiness a[href="/terms/#{term.id}/availability"]})
      # A profile belongs to a session, so the row opens the sessions.
      assert has_element?(live, ~s{#readiness a[href="/terms/#{term.id}/sessions"]})

      # The teacher names read as full names, so that row offers nothing to open.
      refute has_element?(
               live,
               ~s{#readiness a[href="#{NeuZeitWeb.Nav.with_return("/people?tab=teachers", "/terms/#{term.id}")}"]}
             )
    end

    test "reflects non-teaching days changed in term settings", %{conn: conn} do
      term = create_term()
      NeuZeit.Fixtures.session_fixture(term: term)
      {:ok, live, _html} = live(conn, ~p"/terms/#{term}")

      assert has_element?(live, "#readiness", "Teaching weeks: 15. Non-teaching dates: 0.")

      {:ok, settings, _} = live(conn, ~p"/terms/#{term}/settings")
      settings |> element(~s{button[phx-value-date="2026-09-09"]}) |> render_click()
      {:ok, live, _} = live(conn, ~p"/terms/#{term}")

      assert has_element?(live, "#readiness", "Teaching weeks: 15. Non-teaching dates: 1.")
    end
  end

  describe "deleting" do
    test "asks first, and refuses when the term is in use", %{conn: conn} do
      term = create_term()
      {:ok, live, _html} = live(conn, ~p"/terms")

      refute has_element?(live, "#confirm-modal")
      live |> element(~s{button[phx-value-id="#{term.id}"]}) |> render_click()
      assert has_element?(live, "#confirm-modal")

      html = live |> element("#confirm-modal button", "Delete term") |> render_click()
      assert html =~ "Deleted Wintersemester 2026/27."
      assert Catalog.list_terms() == []
    end
  end
end
