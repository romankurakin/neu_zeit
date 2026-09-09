defmodule NeuZeitWeb.SessionLiveTest do
  use NeuZeitWeb.ConnCase, async: true

  alias NeuZeit.Catalog

  setup do
    {:ok, term} =
      Catalog.create_term(%{
        "name" => "Wintersemester 2026/27",
        "starts_on" => "2026-09-07",
        "ends_on" => "2026-12-20"
      })

    {:ok, building} = Catalog.create_building(%{"name" => "Hauptgebäude"})
    {:ok, room} = Catalog.create_room(%{"building_id" => building.id, "name" => "101"})

    {:ok, course} =
      Catalog.create_course(%{"code" => "INF110", "title" => "Programmierung I", "credits" => 8})

    {:ok, component} =
      Catalog.create_course_component(%{
        "course_id" => course.id,
        "kind" => "lecture",
        "allowed_room_ids" => [room.id]
      })

    {:ok, teacher} = Catalog.create_teacher(%{"name" => "Anna Weber"})
    {:ok, other_teacher} = Catalog.create_teacher(%{"name" => "Erik Hoffmann"})
    {:ok, cohort} = Catalog.create_cohort(%{"name" => "WI-1"})
    {:ok, other_cohort} = Catalog.create_cohort(%{"name" => "IT-1"})

    %{
      term: term,
      component: component,
      teacher: teacher,
      other_teacher: other_teacher,
      cohort: cohort,
      other_cohort: other_cohort
    }
  end

  defp session(ctx, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          "term_id" => ctx.term.id,
          "course_component_id" => ctx.component.id,
          "teacher_id" => ctx.teacher.id,
          "week_mask" => [1, 2, 3],
          "duration_slots" => 1,
          "cohort_ids" => [ctx.cohort.id]
        },
        overrides
      )

    {:ok, session} = Catalog.create_session(attrs)
    session
  end

  test "lists the term's sessions", %{conn: conn} = ctx do
    created = session(ctx)
    {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/sessions")

    assert has_element?(live, "#sessions", "INF110")
    assert has_element?(live, "#sessions", "Anna Weber")
    assert has_element?(live, "#sessions-#{created.id}")
  end

  describe "filtering" do
    test "narrows by teacher", %{conn: conn} = ctx do
      mine = session(ctx)
      theirs = session(ctx, %{"teacher_id" => ctx.other_teacher.id})

      {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/sessions")
      assert has_element?(live, "#sessions-#{mine.id}")
      assert has_element?(live, "#sessions-#{theirs.id}")

      live
      |> form("#session-filters")
      |> render_change(%{"teacher_id" => ctx.other_teacher.id})

      refute has_element?(live, "#sessions-#{mine.id}")
      assert has_element?(live, "#sessions-#{theirs.id}")
    end

    test "narrows to sessions with no slot profile", %{conn: conn} = ctx do
      {:ok, profile} =
        Catalog.create_slot_profile(%{
          "term_id" => ctx.term.id,
          "name" => "ANY",
          "cells" => [%{"day" => 1, "slot" => 1}]
        })

      constrained = session(ctx, %{"slot_profile_id" => profile.id})
      free = session(ctx, %{"teacher_id" => ctx.other_teacher.id})

      {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/sessions")
      live |> form("#session-filters") |> render_change(%{"without_profile" => "true"})

      assert has_element?(live, "#sessions-#{free.id}")
      refute has_element?(live, "#sessions-#{constrained.id}")
    end

    test "reset clears every filter", %{conn: conn} = ctx do
      mine = session(ctx)
      {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/sessions")

      live |> form("#session-filters") |> render_change(%{"teacher_id" => ctx.other_teacher.id})
      refute has_element?(live, "#sessions-#{mine.id}")

      live |> element("button", "Reset") |> render_click()
      assert has_element?(live, "#sessions-#{mine.id}")
    end
  end

  describe "the week mask editor" do
    test "starts on every teaching week for a new session", %{conn: conn} = ctx do
      {:ok, _live, html} = live(conn, ~p"/terms/#{ctx.term}/sessions/new")
      assert html =~ "15 weeks"
    end

    test "presets pick alternating weeks", %{conn: conn} = ctx do
      {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/sessions/new")

      html = live |> element(~s{button[phx-value-preset="odd"]}) |> render_click()
      assert html =~ "8 weeks"

      html = live |> element(~s{button[phx-value-preset="even"]}) |> render_click()
      assert html =~ "7 weeks"
    end

    test "a single week can be toggled off and back on", %{conn: conn} = ctx do
      {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/sessions/new")

      html = live |> element(~s{#session-weeks button[phx-value-week="3"]}) |> render_click()
      assert html =~ "14 weeks"

      html = live |> element(~s{#session-weeks button[phx-value-week="3"]}) |> render_click()
      assert html =~ "15 weeks"
    end
  end

  describe "creating" do
    test "saves a session with the chosen weeks and cohorts", %{conn: conn} = ctx do
      {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/sessions/new")

      live |> element(~s{button[phx-value-preset="odd"]}) |> render_click()

      render_hook(live, "selection_changed", %{
        "id" => "session-cohorts",
        "selected" => [ctx.cohort.id, ctx.other_cohort.id]
      })

      live
      |> form("#session-form",
        session: %{
          course_component_id: ctx.component.id,
          teacher_id: ctx.teacher.id,
          duration_slots: 2
        }
      )
      |> render_submit()

      assert [session] = Catalog.list_sessions(ctx.term.id)
      assert session.week_mask == [1, 3, 5, 7, 9, 11, 13, 15]
      assert session.duration_slots == 2
      assert Enum.map(session.cohorts, & &1.name) |> Enum.sort() == ["IT-1", "WI-1"]
    end

    test "a session with no cohort is refused", %{conn: conn} = ctx do
      {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/sessions/new")

      html =
        live
        |> form("#session-form",
          session: %{course_component_id: ctx.component.id, teacher_id: ctx.teacher.id}
        )
        |> render_submit()

      # New sessions require at least one attending group.
      assert html =~ "non-empty list of ids" or html =~ "cohort"
      assert Catalog.list_sessions(ctx.term.id) == []
    end
  end

  test "editing preserves the existing cohorts", %{conn: conn} = ctx do
    created = session(ctx)
    {:ok, live, html} = live(conn, ~p"/terms/#{ctx.term}/sessions/#{created}/edit")

    assert html =~ "WI-1"
    live |> form("#session-form", session: %{duration_slots: 3}) |> render_submit()

    reloaded = Catalog.get_session!(created.id)
    assert reloaded.duration_slots == 3
    assert Enum.map(reloaded.cohorts, & &1.name) == ["WI-1"]
  end

  test "deleting asks first", %{conn: conn} = ctx do
    created = session(ctx)
    {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/sessions")

    refute has_element?(live, "#confirm-modal")
    live |> element(~s{button[phx-value-id="#{created.id}"]}) |> render_click()
    assert has_element?(live, "#confirm-modal")

    live |> element("#confirm-modal button", "Delete session") |> render_click()
    assert Catalog.list_sessions(ctx.term.id) == []
  end
end
