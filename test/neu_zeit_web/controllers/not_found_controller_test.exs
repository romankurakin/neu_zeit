defmodule NeuZeitWeb.NotFoundControllerTest do
  use NeuZeitWeb.ConnCase, async: true

  import NeuZeit.Fixtures
  import NeuZeitWeb.ProblemAssertions

  test "unknown routes return 404", %{conn: conn} do
    conn = get(conn, "/api/not_a_resource")

    assert_problem(conn, 404, :not_found, "Not Found", %{
      "detail" => "API route not found",
      "instance" => "/api/not_a_resource"
    })
  end

  test "unsupported resource methods return 404" do
    conn = build_conn() |> put(~p"/api/terms", %{})

    assert_problem(conn, 404, :not_found, "Not Found", %{
      "detail" => "API route not found",
      "instance" => "/api/terms"
    })

    term = term_fixture()
    conn = build_conn() |> post(~p"/api/terms/#{term.id}", %{})

    assert_problem(conn, 404, :not_found, "Not Found")
  end

  test "GET /api/plans/:id/solve returns 404" do
    plan = plan_fixture()
    conn = build_conn() |> get(~p"/api/plans/#{plan.id}/solve")

    assert_problem(conn, 404, :not_found, "Not Found")
  end
end
