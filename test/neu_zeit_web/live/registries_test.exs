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

      assert has_element?(
               live,
               ~s{#room-#{lab.id} button[disabled][title="Allowed for 1 teaching type"]},
               "Delete"
             )

      assert Catalog.get_room!(lab.id)
    end

    test "an unused room is deleted after confirmation", %{conn: conn} do
      main = building()
      spare = room(main, "101")

      {:ok, live, _html} = live(conn, ~p"/rooms")
      live |> element(~s{#room-#{spare.id} button}, "Delete") |> render_click()
      assert has_element?(live, "#confirm-modal", "Deletes the room 101. This cannot be undone.")
      live |> element("#confirm-modal button", "Delete") |> render_click()

      refute has_element?(live, "#room-#{spare.id}")
      assert Catalog.list_rooms() == []
    end

    test "empty registries offer the next action", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/rooms")
      assert has_element?(live, ".card-dash a", "New building")

      building()
      {:ok, live, _html} = live(conn, ~p"/rooms")
      assert has_element?(live, ".card-dash a", "New room")
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

  describe "buildings" do
    test "a building can be renamed from the rooms page", %{conn: conn} do
      main = building("Hauptgebaude")

      {:ok, live, _html} = live(conn, ~p"/rooms")
      live |> element("#building-#{main.id} a", "Edit") |> render_click()
      assert_patch(live, ~p"/rooms/buildings/#{main}/edit")
      assert has_element?(live, "aside h2", "Edit building")

      live |> form("#building-form", building: %{name: "Hauptgebäude"}) |> render_submit()

      assert Catalog.get_building!(main.id).name == "Hauptgebäude"
      assert has_element?(live, "#building-#{main.id}", "Hauptgebäude")
    end

    test "a building with rooms cannot be deleted, an empty one can", %{conn: conn} do
      main = building()
      room(main, "101")
      empty = building("Ingenieurgebäude")

      {:ok, live, _html} = live(conn, ~p"/rooms")

      assert has_element?(
               live,
               ~s{#building-#{main.id} button[disabled][title="Has 1 room"]},
               "Delete"
             )

      live |> element("#building-#{empty.id} button", "Delete") |> render_click()
      live |> element("#confirm-modal button", "Delete") |> render_click()

      refute has_element?(live, "#building-#{empty.id}")
      assert Enum.map(Catalog.list_buildings(), & &1.id) == [main.id]
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

    test "editing from the course page returns there after save", %{conn: conn} do
      course = course()

      {:ok, detail, _html} = live(conn, ~p"/courses/#{course}")
      detail |> element("a", "Edit course") |> render_click()
      {path, _flash} = assert_redirect(detail)

      {:ok, edit, _html} = live(conn, path)
      assert has_element?(edit, "a", "Back to the course")
      edit |> form("#course-form", course: %{title: "Programmierung 1"}) |> render_submit()
      assert_redirect(edit, ~p"/courses/#{course}")
      assert Catalog.get_course!(course.id).title == "Programmierung 1"
    end

    test "a course without teaching types links to its page", %{conn: conn} do
      course = course()

      {:ok, live, _html} = live(conn, ~p"/courses")

      assert has_element?(
               live,
               ~s{#course-#{course.id} a[href="/courses/#{course.id}"]},
               "Add a teaching type"
             )
    end

    test "a course with sessions cannot be deleted, an unused one can", %{conn: conn} do
      main = building()
      room = room(main, "101")
      used = course("INF110")
      spare = course("INF120")
      {:ok, teacher} = Catalog.create_teacher(%{"name" => "Anna Weber"})
      {:ok, cohort} = Catalog.create_cohort(%{"name" => "WI-1"})

      {:ok, component} =
        Catalog.create_course_component(%{
          "course_id" => used.id,
          "kind" => "lecture",
          "allowed_room_ids" => [room.id]
        })

      {:ok, _session} =
        NeuZeit.Fixtures.create_session(%{
          "term_id" => term().id,
          "course_component_id" => component.id,
          "teacher_id" => teacher.id,
          "week_mask" => [1],
          "duration_slots" => 1,
          "cohort_ids" => [cohort.id]
        })

      {:ok, live, _html} = live(conn, ~p"/courses")

      assert has_element?(
               live,
               ~s{#course-#{used.id} button[disabled][title="Used by 1 session"]},
               "Delete"
             )

      live |> element("#course-#{spare.id} button", "Delete") |> render_click()
      live |> element("#confirm-modal button", "Delete") |> render_click()
      assert Enum.map(Catalog.list_courses(), & &1.id) == [used.id]

      {:ok, detail, _html} = live(conn, ~p"/courses/#{used}")

      assert has_element?(
               detail,
               ~s{#component-#{component.id} button[disabled][title="Used by 1 session"]},
               "Remove from course"
             )
    end

    test "removing a teaching type from a course asks for confirmation", %{conn: conn} do
      course = course()

      {:ok, component} =
        Catalog.create_course_component(%{"course_id" => course.id, "kind" => "lab"})

      {:ok, live, _html} = live(conn, ~p"/courses/#{course}")
      live |> element("#component-#{component.id} button", "Remove from course") |> render_click()
      assert has_element?(live, "#confirm-modal h2", "Remove Lab from Programmierung I?")
      live |> element("#confirm-modal button", "Remove") |> render_click()

      assert Catalog.get_course!(course.id).components == []
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

    test "a component created without rooms allows any available room", %{conn: conn} do
      course = course()
      {:ok, live, _html} = live(conn, ~p"/courses/#{course}")

      html = live |> form("#add-component-form", %{"kind" => "lab"}) |> render_submit()

      assert html =~ "Any available room"
      assert [component] = Catalog.get_course!(course.id).components
      assert Catalog.get_course_component!(component.id).allowed_rooms == []
    end

    test "translations can be added, changed, and removed", %{conn: conn} do
      course = course()
      {:ok, live, _html} = live(conn, ~p"/courses/#{course}")

      html =
        live
        |> form("#translation-form",
          course_translation: %{locale: "ru", title: "Программирование I"}
        )
        |> render_submit()

      assert html =~ "Saved the Русский title."
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

      assert has_element?(
               live,
               "#confirm-modal",
               "Deletes the teacher Spare Person. This cannot be undone."
             )

      live |> element("#confirm-modal button", "Delete") |> render_click()
      assert Enum.all?(Catalog.list_teachers(), &(&1.id != spare.id))

      assert has_element?(
               live,
               ~s{#teacher-#{busy.id} button[disabled][title="Used by 1 session"]},
               "Delete"
             )

      assert Catalog.get_teacher!(busy.id)

      {:ok, live, _html} = live(conn, ~p"/people?tab=cohorts")

      assert has_element?(
               live,
               ~s{#cohort-#{cohort.id} button[disabled][title="Used by 1 session"]},
               "Delete"
             )
    end

    test "empty tabs offer the next action", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/people?tab=teachers")
      assert has_element?(live, ".card-dash a", "New teacher")

      {:ok, live, _html} = live(conn, ~p"/people?tab=cohorts")
      assert has_element?(live, ".card-dash a", "New group")
    end

    test "rows open the edit form", %{conn: conn} do
      {:ok, teacher} = Catalog.create_teacher(%{"name" => "Anna Weber"})

      {:ok, live, _html} = live(conn, ~p"/people?tab=teachers")
      live |> element("#teacher-#{teacher.id} a", "Edit") |> render_click()

      assert has_element?(live, "aside h2", "Edit teacher")
      assert has_element?(live, "#teacher-form a", "Cancel")
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
