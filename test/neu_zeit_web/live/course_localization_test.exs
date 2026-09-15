defmodule NeuZeitWeb.CourseLocalizationTest do
  use NeuZeitWeb.ConnCase, async: true
  import NeuZeit.Fixtures
  alias NeuZeit.{Catalog, Planning}

  test "saved course translations appear in the registry, workload, timetable and calendar", %{
    conn: conn
  } do
    term = term_fixture()
    course = course_fixture(title: "Algorithmen")

    {:ok, _} =
      Catalog.create_course_translation(%{course_id: course.id, locale: "ru", title: "Алгоритмы"})

    component = component_fixture(course: course)
    session = session_fixture(term: term, component: component)
    plan = plan_fixture(term: term)

    placement_fixture(
      plan_id: plan.id,
      session_id: session.id,
      room_id: hd(component.allowed_rooms).id,
      day: 1,
      slot: 1
    )

    conn = Plug.Test.init_test_session(conn, %{"locale" => "ru"})

    for path <- [
          ~p"/courses",
          ~p"/courses/#{course}",
          ~p"/terms/#{term}/workload",
          ~p"/terms/#{term}/sessions",
          ~p"/terms/#{term}/plans/#{plan}",
          ~p"/terms/#{term}/plans/#{plan}?tab=coverage"
        ] do
      {:ok, _view, html} = live(conn, path)
      assert html =~ "Алгоритмы", path
    end

    assert {:ok, _} = Planning.publish_plan(plan.id)
    {:ok, _view, html} = live(conn, ~p"/terms/#{term}/calendar")
    assert html =~ "Алгоритмы"
    assert Catalog.get_course!(course.id).title == "Algorithmen"
  end
end
