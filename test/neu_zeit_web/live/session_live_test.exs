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
      Catalog.create_course(%{"code" => "INF110", "title" => "Programmierung I"})

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

    {:ok, session} = NeuZeit.Fixtures.create_session(attrs)
    session
  end

  test "lists the term's sessions", %{conn: conn} = ctx do
    created = session(ctx)
    {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/sessions")

    assert has_element?(live, "#sessions", "Programmierung I")
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

  test "session list links to teaching load and has no mutation controls", %{conn: conn} = ctx do
    created = session(ctx)
    {:ok, view, _} = live(conn, ~p"/terms/#{ctx.term}/sessions")
    assert has_element?(view, "a[href*='/workload/#{created.workload_id}/edit']")
    refute has_element?(view, "button[phx-click=delete_prompt]")
    refute has_element?(view, "#session-form")
  end

  test "old creation links open the teaching load form", %{conn: conn} = ctx do
    assert {:error, {:live_redirect, %{to: path}}} =
             live(conn, ~p"/terms/#{ctx.term}/sessions/new")

    assert URI.parse(path).path == "/terms/#{ctx.term.id}/workload/new"
  end

  test "old edit links keep the return path and open the saved teaching load",
       %{conn: conn} = ctx do
    created = session(ctx)
    return_to = ~p"/terms/#{ctx.term}/calendar?week=2"

    assert {:error, {:live_redirect, %{to: path}}} =
             live(conn, ~p"/terms/#{ctx.term}/sessions/#{created}/edit?return_to=#{return_to}")

    assert URI.parse(path).path == "/terms/#{ctx.term.id}/workload/#{created.workload_id}/edit"
    assert URI.decode_query(URI.parse(path).query)["return_to"] == return_to
  end
end
