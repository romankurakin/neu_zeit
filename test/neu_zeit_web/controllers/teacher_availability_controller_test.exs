defmodule NeuZeitWeb.TeacherAvailabilityControllerTest do
  use NeuZeitWeb.ConnCase, async: true

  import NeuZeit.Fixtures
  import NeuZeitWeb.ProblemAssertions

  test "atomically replaces and reads recurring teacher availability", %{conn: conn} do
    term = term_fixture()
    teacher = teacher_fixture()
    path = "/api/terms/#{term.id}/teachers/#{teacher.id}/availability"

    conn =
      put(conn, path, %{
        cells: [
          %{day: 6, slot: 1},
          %{day: 6, slot: 2}
        ]
      })

    assert %{
             "data" => [
               %{"day" => 6, "slot" => 1},
               %{"day" => 6, "slot" => 2}
             ]
           } = json_response(conn, 200)

    conn = get(build_conn(), path)
    assert %{"data" => cells} = json_response(conn, 200)
    assert Enum.map(cells, &{&1["day"], &1["slot"]}) == [{6, 1}, {6, 2}]

    conn = put(build_conn(), path, %{cells: []})
    assert %{"data" => []} = json_response(conn, 200)
  end

  test "rejects missing and malformed cells without clearing availability", %{conn: conn} do
    term = term_fixture()
    teacher = teacher_fixture()
    path = "/api/terms/#{term.id}/teachers/#{teacher.id}/availability"

    conn = put(conn, path, %{cells: [%{day: 6, slot: 1}]})
    assert %{"data" => [%{"day" => 6, "slot" => 1}]} = json_response(conn, 200)

    conn = put(build_conn(), path, %{})

    assert_problem(conn, 400, :bad_request, "Bad Request", %{
      "detail" => "cells must be present and must be a list"
    })

    conn = put(build_conn(), path, %{cells: [1]})
    assert_problem(conn, 422, :validation, "Validation Error")

    conn = get(build_conn(), path)
    assert %{"data" => [%{"day" => 6, "slot" => 1}]} = json_response(conn, 200)
  end
end
