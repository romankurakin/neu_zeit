defmodule NeuZeitWeb.ScheduleControllerTest do
  use NeuZeitWeb.ConnCase, async: true

  import NeuZeit.Fixtures

  alias NeuZeit.Planning

  test "occurrences report sessions missing from the active plan", %{conn: conn} do
    term = term_fixture()
    room = room_fixture()
    component = component_fixture(rooms: [room])
    original_session = session_fixture(term: term, component: component)
    active = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: active.id,
      session_id: original_session.id,
      room_id: room.id,
      day: 1,
      slot: 1
    })

    assert {:ok, _active} = Planning.publish_plan(active.id)

    new_session = session_fixture(term: term, component: component)

    conn = get(conn, ~p"/api/terms/#{term.id}/occurrences")

    assert %{
             "data" => occurrences,
             "meta" => %{"unplaced_session_ids" => [unplaced_id]}
           } = json_response(conn, 200)

    assert occurrences != []
    assert unplaced_id == new_session.id

    replacement = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: replacement.id,
      session_id: original_session.id,
      room_id: room.id,
      day: 1,
      slot: 1
    })

    placement_fixture(%{
      plan_id: replacement.id,
      session_id: new_session.id,
      room_id: room.id,
      day: 2,
      slot: 1
    })

    assert {:ok, _replacement} = Planning.publish_plan(replacement.id)

    conn = build_conn() |> get(~p"/api/terms/#{term.id}/occurrences")
    assert %{"meta" => %{"unplaced_session_ids" => []}} = json_response(conn, 200)
  end
end
