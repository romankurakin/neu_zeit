defmodule NeuZeitWeb.PlanControllerTest do
  use NeuZeitWeb.ConnCase, async: true

  import NeuZeit.Fixtures
  import NeuZeitWeb.ProblemAssertions

  test "POST and PATCH /api/plans reject read-only workflow fields", %{conn: conn} do
    term = term_fixture()

    conn =
      post(conn, ~p"/api/plans", %{
        "plan" => %{"term_id" => term.id, "name" => "Bypass attempt", "status" => "active"}
      })

    assert_problem(conn, 422, :validation, "Validation Error", %{
      "errors" => [%{"code" => "invalid", "detail" => "is read-only", "pointer" => "#/status"}]
    })

    plan = plan_fixture(term: term)
    conn = build_conn() |> patch(~p"/api/plans/#{plan.id}", %{"plan" => %{"status" => "active"}})

    assert_problem(conn, 422, :validation, "Validation Error", %{
      "errors" => [%{"code" => "invalid", "detail" => "is read-only", "pointer" => "#/status"}]
    })
  end

  test "POST /api/plans/:id/publish publishes a complete plan", %{conn: conn} do
    term = term_fixture()
    room = room_fixture()
    component = component_fixture(rooms: [room])
    session = session_fixture(term: term, component: component)
    plan = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: plan.id,
      session_id: session.id,
      room_id: room.id,
      day: 1,
      slot: 1
    })

    plan_id = plan.id
    conn = post(conn, ~p"/api/plans/#{plan.id}/publish", %{})

    assert %{"data" => %{"id" => ^plan_id, "status" => "active"}} = json_response(conn, 200)

    conn = build_conn() |> post(~p"/api/plans/#{plan.id}/publish", %{})

    assert_problem(conn, 422, :validation, "Validation Error", %{
      "errors" => [
        %{
          "code" => "invalid",
          "detail" => "only draft plans can be published",
          "pointer" => "#/base"
        }
      ]
    })
  end
end
