defmodule NeuZeitWeb.RegistriesTest do
  use NeuZeitWeb.ConnCase, async: true

  alias NeuZeit.Catalog

  defp building(name \\ "Hauptgebäude") do
    {:ok, building} = Catalog.create_building(%{"name" => name})
    building
  end

  defp room(building, name) do
    {:ok, room} = Catalog.create_room(%{"building_id" => building.id, "name" => name})
    room
  end

  defp term do
    {:ok, term} =
      Catalog.create_term(%{
        "name" => "Wintersemester 2026/27",
        "starts_on" => "2026-09-07",
        "ends_on" => "2026-12-20"
      })

    term
  end

  defp course(code \\ "INF110") do
    {:ok, course} =
      Catalog.create_course(%{"code" => code, "title" => "Programmierung I"})

    course
  end

  describe "rooms" do
    test "flags names that carry no building information", %{conn: conn} do
      main = building()
      room(main, "101")
      room(main, "Sporthalle")

      {:ok, live, _html} = live(conn, ~p"/rooms")

      # Names with non-numeric characters prompt a building review.
      assert has_element?(live, "#rooms", "Check building")
      assert has_element?(live, "#rooms", "Number only")
    end

    test "shows how many components allow each room", %{conn: conn} do
      main = building()
      lab = room(main, "L12")
      course = course()

      {:ok, _component} =
        Catalog.create_course_component(%{
          "course_id" => course.id,
          "kind" => "lab",
          "allowed_room_ids" => [lab.id]
        })

      {:ok, live, _html} = live(conn, ~p"/rooms")
      assert has_element?(live, "#room-#{lab.id}", "1 teaching type")
    end

    test "a room a component still allows is protected from deletion", %{conn: conn} do
      main = building()
      lab = room(main, "L12")
      course = course()

      {:ok, _component} =
        Catalog.create_course_component(%{
          "course_id" => course.id,
          "kind" => "lab",
          "allowed_room_ids" => [lab.id]
        })

      {:ok, live, _html} = live(conn, ~p"/rooms")
      live |> element(~s{button[phx-value-id="#{lab.id}"]}) |> render_click()
      html = live |> element("#confirm-modal button", "Delete") |> render_click()

      assert html =~ "is used by a teaching type or a scheduled session"
      assert Catalog.get_room!(lab.id)
    end

    test "filtering narrows the list to one building", %{conn: conn} do
      main = building()
      other = building("Ingenieurgebäude")
      a = room(main, "101")
      b = room(other, "11")

      {:ok, live, _html} = live(conn, ~p"/rooms")
      assert has_element?(live, "#room-#{a.id}")
      assert has_element?(live, "#room-#{b.id}")

      live |> element("#building-filter") |> render_change(%{"building_id" => main.id})

      assert has_element?(live, "#room-#{a.id}")
      refute has_element?(live, "#room-#{b.id}")
    end
  end

  describe "courses" do
    test "creates a course by title and can add or clear its code", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/courses/new")
      refute has_element?(view, "[name='course[credits]']")
      assert has_element?(view, "label", "Code (optional)")
      view |> form("#course-form", course: %{title: "Mathematics"}) |> render_submit()
      assert_patch(view, ~p"/courses")
      assert [course] = Catalog.list_courses()
      assert course.code == nil
      assert has_element?(view, "#course-#{course.id} a", "Mathematics")

      view |> element("#course-#{course.id} a", "Edit") |> render_click()
      view |> form("#course-form", course: %{code: "MAT101"}) |> render_submit()
      assert Catalog.get_course!(course.id).code == "MAT101"
      view |> element("#course-#{course.id} a", "Edit") |> render_click()
      view |> form("#course-form", course: %{code: ""}) |> render_submit()
      assert Catalog.get_course!(course.id).code == nil

      {:ok, detail, _html} = live(conn, ~p"/courses/#{course}")
      assert has_element?(detail, "h1", "Mathematics")
    end

    test "dragging a room into the pool updates the component", %{conn: conn} do
      main = building()
      first = room(main, "101")
      second = room(main, "102")
      course = course()

      {:ok, component} =
        Catalog.create_course_component(%{
          "course_id" => course.id,
          "kind" => "lecture",
          "allowed_room_ids" => [first.id]
        })

      {:ok, live, _html} = live(conn, ~p"/courses/#{course}")

      render_hook(live, "selection_changed", %{
        "id" => "component-#{component.id}-rooms",
        "selected" => [first.id, second.id]
      })

      reloaded = Catalog.get_course_component!(component.id)

      assert Enum.map(reloaded.allowed_rooms, & &1.id) |> Enum.sort() ==
               Enum.sort([first.id, second.id])
    end

    test "a pool of one is called out, a pool of three is not", %{conn: conn} do
      main = building()
      only = room(main, "L12")
      course = course()

      {:ok, _component} =
        Catalog.create_course_component(%{
          "course_id" => course.id,
          "kind" => "lab",
          "allowed_room_ids" => [only.id]
        })

      {:ok, _live, html} = live(conn, ~p"/courses/#{course}")
      assert html =~ "Check whether alternatives are available."
    end

    test "offers only the component kinds the course does not have", %{conn: conn} do
      main = building()
      lecture_room = room(main, "101")
      course = course()

      {:ok, _component} =
        Catalog.create_course_component(%{
          "course_id" => course.id,
          "kind" => "lecture",
          "allowed_room_ids" => [lecture_room.id]
        })

      {:ok, live, _html} = live(conn, ~p"/courses/#{course}")

      # A course may hold at most one component per kind.
      refute has_element?(live, ~s{#add-component-form option[value="lecture"]})
      assert has_element?(live, ~s{#add-component-form option[value="lab"]})

      live
      |> form("#add-component-form", %{"kind" => "lab", "room_ids" => [lecture_room.id]})
      |> render_submit()

      refute has_element?(live, ~s{#add-component-form option[value="lab"]})
    end

    test "a component cannot be created without a room", %{conn: conn} do
      course = course()
      {:ok, live, _html} = live(conn, ~p"/courses/#{course}")

      html = live |> form("#add-component-form", %{"kind" => "lab"}) |> render_submit()

      assert html =~ "at least one room"
      assert Catalog.get_course!(course.id).components == []
    end

    test "translations can be added, changed, and removed", %{conn: conn} do
      course = course()
      {:ok, live, _html} = live(conn, ~p"/courses/#{course}")

      live
      |> form("#translation-form",
        course_translation: %{locale: "ru", title: "Программирование I"}
      )
      |> render_submit()

      assert Catalog.get_course_translation(course.id, "ru").title == "Программирование I"

      live
      |> form("#translation-form",
        course_translation: %{locale: "ru", title: "Программирование 1"}
      )
      |> render_submit()

      assert Catalog.get_course_translation(course.id, "ru").title == "Программирование 1"
      assert length(Catalog.list_course_translations(course.id)) == 1

      live |> element(~s{button[phx-value-locale="ru"]}) |> render_click()
      assert Catalog.list_course_translations(course.id) == []
    end
  end

  describe "people" do
    test "flags an abbreviation standing in for a person", %{conn: conn} do
      {:ok, _placeholder} = Catalog.create_teacher(%{"name" => "Lch"})
      {:ok, _real} = Catalog.create_teacher(%{"name" => "Anna Weber"})

      {:ok, live, _html} = live(conn, ~p"/people")
      assert has_element?(live, "#teachers", "Check full name")
    end

    test "distinguishes a language subgroup from an aggregate code", %{conn: conn} do
      {:ok, _subgroup} = Catalog.create_cohort(%{"name" => "D1"})
      {:ok, _aggregate} = Catalog.create_cohort(%{"name" => "ФК(д)"})
      {:ok, _plain} = Catalog.create_cohort(%{"name" => "WI-1"})

      {:ok, live, _html} = live(conn, ~p"/people?tab=cohorts")

      assert has_element?(live, "#cohorts", "Language subgroup")
      assert has_element?(live, "#cohorts", "Check group membership")
    end

    test "a placeholder teacher can be renamed where the checklist points", %{conn: conn} do
      {:ok, placeholder} = Catalog.create_teacher(%{"name" => "Lch"})

      # The flagged teacher name can be corrected on this page.
      {:ok, live, _html} = live(conn, ~p"/people?tab=teachers&edit=#{placeholder.id}")

      live
      |> form("#teacher-form", teacher: %{name: "Christoph Lehmann"})
      |> render_submit()

      assert Catalog.get_teacher!(placeholder.id).name == "Christoph Lehmann"
      refute has_element?(live, "#teachers", "Check full name")
    end

    test "an unused teacher can be deleted, a teaching one cannot", %{conn: conn} do
      {:ok, spare} = Catalog.create_teacher(%{"name" => "Spare Person"})
      {:ok, busy} = Catalog.create_teacher(%{"name" => "Busy Person"})

      main = building()
      room = room(main, "101")
      course = course()

      {:ok, component} =
        Catalog.create_course_component(%{
          "course_id" => course.id,
          "kind" => "lecture",
          "allowed_room_ids" => [room.id]
        })

      {:ok, cohort} = Catalog.create_cohort(%{"name" => "WI-1"})

      {:ok, _session} =
        NeuZeit.Fixtures.create_session(%{
          "term_id" => term().id,
          "course_component_id" => component.id,
          "teacher_id" => busy.id,
          "week_mask" => [1],
          "duration_slots" => 1,
          "cohort_ids" => [cohort.id]
        })

      {:ok, live, _html} = live(conn, ~p"/people?tab=teachers")

      live |> element(~s{button[phx-value-id="#{spare.id}"]}) |> render_click()
      live |> element("#confirm-modal button", "Delete") |> render_click()
      assert Enum.all?(Catalog.list_teachers(), &(&1.id != spare.id))

      live |> element(~s{button[phx-value-id="#{busy.id}"]}) |> render_click()
      html = live |> element("#confirm-modal button", "Delete") |> render_click()

      assert html =~ "still teaches"
      assert Catalog.get_teacher!(busy.id)
    end

    test "an aggregate cohort can be renamed into a real section", %{conn: conn} do
      {:ok, aggregate} = Catalog.create_cohort(%{"name" => "ФК(д)"})

      {:ok, live, _html} = live(conn, ~p"/people?tab=cohorts&edit=#{aggregate.id}")
      live |> form("#cohort-form", cohort: %{name: "Sport-A"}) |> render_submit()

      assert Catalog.get_cohort!(aggregate.id).name == "Sport-A"
      refute has_element?(live, "#cohorts", "Check group membership")
    end

    test "adding a teacher keeps the tab", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/people?tab=teachers&new=1")

      live |> form("#teacher-form", teacher: %{name: "Jana Richter"}) |> render_submit()

      assert has_element?(live, "#teachers", "Jana Richter")
    end
  end
end
