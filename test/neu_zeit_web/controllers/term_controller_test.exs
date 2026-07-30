defmodule NeuZeitWeb.TermControllerTest do
  use NeuZeitWeb.ConnCase, async: true

  import NeuZeitWeb.ProblemAssertions

  test "POST /api/terms creates a term", %{conn: conn} do
    conn =
      post(conn, ~p"/api/terms", %{
        "term" => %{
          "name" => "Autumn 2026",
          "starts_on" => "2026-08-31",
          "ends_on" => "2026-12-19",
          "excluded_dates" => []
        }
      })

    assert %{"data" => %{"id" => id, "weeks_count" => 16}} = json_response(conn, 201)
    assert {:ok, _uuid} = Ecto.UUID.cast(id)
  end

  test "excluded dates can be added and removed one at a time", %{conn: conn} do
    conn =
      post(conn, ~p"/api/terms", %{
        "term" => %{
          "name" => "Autumn 2026",
          "starts_on" => "2026-08-31",
          "ends_on" => "2026-12-19",
          "excluded_dates" => []
        }
      })

    assert %{"data" => %{"id" => id}} = json_response(conn, 201)

    conn = post(build_conn(), ~p"/api/terms/#{id}/excluded_dates", %{"date" => "2026-09-07"})
    assert %{"data" => %{"excluded_dates" => ["2026-09-07"]}} = json_response(conn, 200)

    conn = delete(build_conn(), ~p"/api/terms/#{id}/excluded_dates/2026-09-07")
    assert %{"data" => %{"excluded_dates" => []}} = json_response(conn, 200)

    conn = post(build_conn(), ~p"/api/terms/#{id}/excluded_dates", %{"date" => "not-a-date"})

    assert_problem(conn, 400, :bad_request, "Bad Request", %{
      "detail" => "date must be an ISO 8601 date"
    })
  end

  test "GET /api/terms/:id returns 400 for an invalid UUID", %{conn: conn} do
    conn = get(conn, "/api/terms/not-a-uuid")

    assert_problem(conn, 400, :bad_request, "Bad Request", %{
      "detail" => "id must be a valid UUID",
      "instance" => "/api/terms/not-a-uuid"
    })
  end

  test "GET /api/terms/:id returns 404 for a missing term" do
    id = "00000000-0000-0000-0000-000000000000"
    conn = build_conn() |> get("/api/terms/#{id}")

    assert_problem(conn, 404, :not_found, "Not Found", %{
      "detail" => "Resource not found",
      "instance" => "/api/terms/#{id}"
    })
  end
end
