defmodule NeuZeitWeb.CourseControllerTest do
  use NeuZeitWeb.ConnCase, async: true

  import NeuZeit.Fixtures

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
