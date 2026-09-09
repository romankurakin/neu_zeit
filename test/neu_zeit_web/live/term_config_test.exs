defmodule NeuZeitWeb.TermConfigTest do
  use NeuZeitWeb.ConnCase, async: true

  alias NeuZeit.Catalog

  setup do
    {:ok, term} =
      Catalog.create_term(%{
        "name" => "Wintersemester 2026/27",
        "starts_on" => "2026-09-07",
        "ends_on" => "2026-12-20"
      })

    %{term: term}
  end

  defp teaching_grid, do: NeuZeit.Config.grid!()

  defp profile(term, name, cells) do
    {:ok, profile} =
      Catalog.create_slot_profile(%{"term_id" => term.id, "name" => name, "cells" => cells})

    profile
  end

  # Use at least one group, as required by session creation.
  defp session_fixture(term, teacher, opts) do
    {:ok, cohort} = Catalog.create_cohort(%{"name" => "G#{System.unique_integer([:positive])}"})

    {:ok, building} =
      Catalog.create_building(%{"name" => "Haupt#{System.unique_integer([:positive])}"})

    {:ok, room} =
      Catalog.create_room(%{
        "building_id" => building.id,
        "name" => "R#{System.unique_integer([:positive])}"
      })

    {:ok, course} =
      Catalog.create_course(%{
        "code" => "C#{System.unique_integer([:positive])}",
        "title" => "Course",
        "credits" => 5
      })

    {:ok, component} =
      Catalog.create_course_component(%{
        "course_id" => course.id,
        "kind" => "lecture",
        "allowed_room_ids" => [room.id]
      })

    Catalog.create_session(%{
      "term_id" => term.id,
      "course_component_id" => component.id,
      "teacher_id" => teacher.id,
      "week_mask" => [1, 2, 3],
      "duration_slots" => Keyword.get(opts, :duration, 1),
      "slot_profile_id" => Keyword.get(opts, :slot_profile_id),
      "cohort_ids" => [cohort.id]
    })
  end

  describe "slot profiles" do
    test "adds only the weekday daytime profile", %{conn: conn, term: term} do
      {:ok, live, _html} = live(conn, ~p"/terms/#{term}/slot-profiles")

      assert has_element?(live, "#create-default-profiles")
      live |> element("#create-default-profiles") |> render_click()

      names = Catalog.list_slot_profiles(term.id) |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["Weekdays, daytime"]
      refute has_element?(live, "#create-default-profiles")
    end

    test "creating them twice is a no-op", %{conn: conn, term: term} do
      {:ok, live, _html} = live(conn, ~p"/terms/#{term}/slot-profiles")

      live |> element("#create-default-profiles") |> render_click()
      count = length(Catalog.list_slot_profiles(term.id))
      render_click(live, "create_defaults")

      assert length(Catalog.list_slot_profiles(term.id)) == count
    end

    test "localizes built-in labels without overwriting stored or custom names", %{
      conn: conn,
      term: term
    } do
      {:ok, [preset]} = Catalog.ensure_default_slot_profiles(term)
      custom = profile(term, "My morning", [%{day: 1, slot: 1}])

      for {locale, label} <- [
            {"ru", "Будни, дневное время"},
            {"en", "Weekdays, daytime"},
            {"de", "Mo-Fr, tagsüber"}
          ] do
        localized_conn = Plug.Test.init_test_session(conn, %{"locale" => locale})
        {:ok, view, _html} = live(localized_conn, ~p"/terms/#{term}/slot-profiles/#{preset}/edit")
        assert has_element?(view, "#profile-#{preset.id}", label)
        assert has_element?(view, "#profile-#{custom.id}", "My morning")
        assert has_element?(view, "input[name='slot_profile[name]'][value='#{label}']")
        view |> form("#profile-form", slot_profile: %{name: label}) |> render_submit()
        assert Catalog.get_slot_profile!(preset.id).name == "Weekdays, daytime"
      end
    end

    test "renamed built-in profiles keep their user label and identity", %{conn: conn, term: term} do
      {:ok, [preset]} = Catalog.ensure_default_slot_profiles(term)
      localized_conn = Plug.Test.init_test_session(conn, %{"locale" => "ru"})
      {:ok, view, _} = live(localized_conn, ~p"/terms/#{term}/slot-profiles/#{preset}/edit")
      view |> form("#profile-form", slot_profile: %{name: "Наши будни"}) |> render_submit()
      assert has_element?(view, "#profile-#{preset.id}", "Наши будни")
      assert {:ok, [same]} = Catalog.ensure_default_slot_profiles(term)
      assert same.id == preset.id
      assert same.name == "Наши будни"
    end

    test "painting the grid replaces the profile's starts", %{conn: conn, term: term} do
      profile = profile(term, "NARROW", [%{"day" => 1, "slot" => 1}])
      {:ok, live, _html} = live(conn, ~p"/terms/#{term}/slot-profiles/#{profile}/edit")

      render_hook(live, "grid_changed", %{
        "id" => "profile-grid-#{profile.id}",
        "cells" => [%{"day" => 2, "slot" => 3}, %{"day" => 2, "slot" => 4}]
      })

      cells =
        Catalog.get_slot_profile!(profile.id).cells
        |> Enum.map(&{&1.day, &1.slot})
        |> Enum.sort()

      assert cells == [{2, 3}, {2, 4}]
    end

    test "warns when no start leaves room for a longer session", %{conn: conn, term: term} do
      last_slot = length(teaching_grid().slots)
      profile = profile(term, "EDGE_ONLY", [%{"day" => 1, "slot" => last_slot}])

      {:ok, _live, html} = live(conn, ~p"/terms/#{term}/slot-profiles/#{profile}/edit")

      # Every start sits in the final slot, so a two-slot session cannot fit.
      assert html =~ "Sessions longer than one slot will not fit."
    end

    test "a profile a session still uses is protected", %{conn: conn, term: term} do
      profile = profile(term, "IN_USE", [%{"day" => 1, "slot" => 1}])
      {:ok, teacher} = Catalog.create_teacher(%{"name" => "Anna Weber"})
      {:ok, _session} = session_fixture(term, teacher, slot_profile_id: profile.id)

      {:ok, live, _html} = live(conn, ~p"/terms/#{term}/slot-profiles")
      live |> element(~s{button[phx-value-id="#{profile.id}"]}) |> render_click()
      html = live |> element("#confirm-modal button", "Delete profile") |> render_click()

      assert html =~ "still assigned to a session"
      assert Catalog.get_slot_profile!(profile.id)
    end
  end

  describe "teacher availability" do
    setup %{term: term} do
      {:ok, teacher} = Catalog.create_teacher(%{"name" => "Marat Zhaksylykov"})
      %{teacher: teacher, term: term}
    end

    test "an empty allow-list reads as unrestricted", %{conn: conn, term: term, teacher: teacher} do
      {:ok, _live, html} = live(conn, ~p"/terms/#{term}/availability/#{teacher}")

      assert html =~ "Any time is allowed."
      assert Catalog.list_teacher_availability(term.id, teacher.id) == []
    end

    test "painting cells stores the allow-list", %{conn: conn, term: term, teacher: teacher} do
      {:ok, live, _html} = live(conn, ~p"/terms/#{term}/availability/#{teacher}")

      render_hook(live, "grid_changed", %{
        "id" => "availability-#{teacher.id}",
        "cells" => [%{"day" => 6, "slot" => 1}, %{"day" => 6, "slot" => 2}]
      })

      cells =
        Catalog.list_teacher_availability(term.id, teacher.id)
        |> Enum.map(&{&1.day, &1.slot})

      assert cells == [{6, 1}, {6, 2}]
    end

    test "clearing restores unrestricted availability", %{
      conn: conn,
      term: term,
      teacher: teacher
    } do
      {:ok, _} =
        Catalog.replace_teacher_availability(term.id, teacher.id, [%{"day" => 6, "slot" => 1}])

      {:ok, live, _html} = live(conn, ~p"/terms/#{term}/availability/#{teacher}")
      live |> element("button", "Remove restriction") |> render_click()

      assert Catalog.list_teacher_availability(term.id, teacher.id) == []
    end

    test "a change that would strand a session is refused and shown", %{
      conn: conn,
      term: term,
      teacher: teacher
    } do
      saturday = profile(term, "SAT_ONLY", for(slot <- 1..3, do: %{"day" => 6, "slot" => slot}))
      {:ok, _session} = session_fixture(term, teacher, slot_profile_id: saturday.id)

      {:ok, live, _html} = live(conn, ~p"/terms/#{term}/availability/#{teacher}")

      # Monday only: the intersection with a Saturday-only profile is empty, so
      # the session would have nowhere legal to start.
      html =
        render_hook(live, "grid_changed", %{
          "id" => "availability-#{teacher.id}",
          "cells" => [%{"day" => 1, "slot" => 1}]
        })

      assert Catalog.list_teacher_availability(term.id, teacher.id) == []
      refute html =~ "1 cell allowed"
    end
  end
end
