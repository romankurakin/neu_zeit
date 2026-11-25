defmodule NeuZeitWeb.CourseControllerTest do
  use NeuZeitWeb.ConnCase, async: true

  import NeuZeit.Fixtures
  import NeuZeitWeb.ProblemAssertions

  alias NeuZeit.Catalog

  defp list(query), do: build_conn() |> get(~p"/api/courses?#{query}") |> json_response(200)

  defp titles(%{"data" => courses}), do: Enum.map(courses, & &1["title"])

  describe "GET /api/courses paging and search" do
    test "returns one page and the number of matching courses" do
      for title <- ["Algebra", "Biology", "Chemistry"], do: course_fixture(%{title: title})

      first = list(limit: 2)
      assert titles(first) == ["Algebra", "Biology"]
      assert first["meta"] == %{"total" => 3, "limit" => 2, "offset" => 0}

      last = list(limit: 2, offset: 2)
      assert titles(last) == ["Chemistry"]
      assert last["meta"] == %{"total" => 3, "limit" => 2, "offset" => 2}

      assert list(%{})["meta"] == %{"total" => 3, "limit" => 50, "offset" => 0}
    end

    test "searches codes and titles case-insensitively, wildcards literally" do
      course_fixture(%{title: "Linear Algebra", code: "MATH-101"})
      course_fixture(%{title: "Physics", code: "PHY_1"})
      course_fixture(%{title: "Physiology", code: "PHY-2"})

      assert titles(list(q: "math")) == ["Linear Algebra"]
      assert titles(list(q: "ALGEBRA")) == ["Linear Algebra"]
      assert titles(list(q: "_")) == ["Physics"]
      assert titles(list(q: "%")) == []
      assert list(q: "phy")["meta"]["total"] == 2
      assert list(q: "  ")["meta"]["total"] == 3
    end

    test "searches translated titles in the requested locale" do
      course = course_fixture(%{title: "Algorithmen"})

      {:ok, _translation} =
        Catalog.create_course_translation(%{
          course_id: course.id,
          locale: "ru",
          title: "Алгоритмы"
        })

      course_fixture(%{title: "Datenbanken"})

      assert titles(list(locale: "ru", q: "алгоритм")) == ["Алгоритмы"]
      assert titles(list(locale: "en", q: "algorithm")) == ["Algorithmen"]
    end

    test "rejects invalid paging and search values" do
      too_long = String.duplicate("a", 101)

      for {query, detail} <- [
            {[limit: 0], "limit must be an integer from 1 to 100"},
            {[limit: 101], "limit must be an integer from 1 to 100"},
            {[limit: "ten"], "limit must be an integer from 1 to 100"},
            {[offset: -1], "offset must be an integer from 0 to 1000000"},
            {[offset: "1e3"], "offset must be an integer from 0 to 1000000"},
            {[q: too_long], "q must be at most 100 characters"}
          ] do
        conn = build_conn() |> get(~p"/api/courses?#{query}")
        assert_problem(conn, 400, :bad_request, "Bad Request", %{"detail" => detail})
      end
    end
  end

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
