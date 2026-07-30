defmodule NeuZeitWeb.BuildingControllerTest do
  use NeuZeitWeb.ConnCase, async: true

  import NeuZeit.Fixtures
  import NeuZeitWeb.ProblemAssertions

  test "DELETE /api/buildings/:id returns 409 for a referenced building", %{conn: conn} do
    building = building_fixture()
    room_fixture(building: building)

    conn = delete(conn, ~p"/api/buildings/#{building.id}")

    assert_problem(conn, 409, :conflict, "Resource Conflict", %{
      "detail" => "Resource is referenced by other records"
    })
  end

  test "POST /api/buildings returns 409 for a duplicate name", %{conn: conn} do
    building = building_fixture()

    conn = post(conn, ~p"/api/buildings", %{"building" => %{"name" => building.name}})

    assert_problem(conn, 409, :conflict, "Resource Conflict", %{
      "detail" => "Request conflicts with existing resource state.",
      "errors" => [
        %{"code" => "invalid", "detail" => "has already been taken", "pointer" => "#/name"}
      ]
    })
  end
end
