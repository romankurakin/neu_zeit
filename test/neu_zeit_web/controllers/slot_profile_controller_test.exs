defmodule NeuZeitWeb.SlotProfileControllerTest do
  use NeuZeitWeb.ConnCase, async: true

  import NeuZeit.Fixtures

  test "creates default profiles for a term and lists their cells", %{conn: conn} do
    term = term_fixture()

    conn = post(conn, "/api/terms/#{term.id}/slot_profiles/defaults")
    assert %{"data" => profiles} = json_response(conn, 201)
    assert [%{"name" => "Weekdays, daytime"}] = profiles

    conn = get(build_conn(), "/api/slot_profiles?term_id=#{term.id}")
    assert %{"data" => listed} = json_response(conn, 200)

    [daytime] = listed
    assert length(daytime["cells"]) == 20
  end

  test "creates and updates an administrator-defined profile", %{conn: conn} do
    term = term_fixture()

    conn =
      post(conn, "/api/slot_profiles", %{
        slot_profile: %{
          term_id: term.id,
          name: "Guest lecturer",
          cells: [%{day: 2, slot: 3}]
        }
      })

    assert %{"data" => %{"id" => id, "cells" => [%{"day" => 2, "slot" => 3}]}} =
             json_response(conn, 201)

    conn =
      patch(build_conn(), "/api/slot_profiles/#{id}", %{
        slot_profile: %{name: "Guest fixed", cells: [%{day: 4, slot: 2}]}
      })

    assert %{
             "data" => %{
               "name" => "Guest fixed",
               "cells" => [%{"day" => 4, "slot" => 2}]
             }
           } = json_response(conn, 200)
  end
end
