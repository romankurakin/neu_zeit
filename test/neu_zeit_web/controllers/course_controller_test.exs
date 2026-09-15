defmodule NeuZeitWeb.CourseControllerTest do
  use NeuZeitWeb.ConnCase, async: true

  import NeuZeit.Fixtures

  test "creates and lists a course with only a title", %{conn: conn} do
    conn = post(conn, ~p"/api/courses", %{course: %{title: "Mathematics"}})
    assert %{"data" => course} = json_response(conn, 201)
    assert course["title"] == "Mathematics"
    assert course["code"] == nil
    refute Map.has_key?(course, "credits")

    for path <- [~p"/api/courses", ~p"/api/courses?locale=ru"] do
      assert %{"data" => [listed]} = build_conn() |> get(path) |> json_response(200)
      assert listed["id"] == course["id"]
      assert listed["title"] == "Mathematics"
      assert listed["code"] == nil
      refute Map.has_key?(listed, "credits")
    end
  end

  test "translations are created through the API and localize the course index", %{conn: conn} do
    course = course_fixture(%{title: "Algorithmen"})

    conn =
      post(conn, ~p"/api/courses/#{course.id}/translations", %{
        "course_translation" => %{"locale" => "ru", "title" => "Алгоритмы"}
      })

    assert %{"data" => %{"locale" => "ru", "title" => "Алгоритмы"}} = json_response(conn, 201)

    conn = build_conn() |> get(~p"/api/courses?locale=ru")
    assert %{"data" => courses} = json_response(conn, 200)
    localized = Enum.find(courses, &(&1["id"] == course.id))
    assert localized["title"] == "Алгоритмы"

    # Locales without a translation fall back to the base title.
    conn = build_conn() |> get(~p"/api/courses?locale=en")
    assert %{"data" => courses} = json_response(conn, 200)
    fallback = Enum.find(courses, &(&1["id"] == course.id))
    assert fallback["title"] == "Algorithmen"
  end

  test "duplicate translations for a locale return a conflict", %{conn: conn} do
    course = course_fixture()

    params = %{"course_translation" => %{"locale" => "de", "title" => "Titel"}}

    assert post(conn, ~p"/api/courses/#{course.id}/translations", params)
           |> json_response(201)

    assert build_conn()
           |> post(~p"/api/courses/#{course.id}/translations", params)
           |> json_response(409)
  end

  test "translations for an unknown course return 404", %{conn: conn} do
    conn =
      post(conn, ~p"/api/courses/#{Ecto.UUID.generate()}/translations", %{
        "course_translation" => %{"locale" => "ru", "title" => "Алгоритмы"}
      })

    assert json_response(conn, 404)
  end
end
