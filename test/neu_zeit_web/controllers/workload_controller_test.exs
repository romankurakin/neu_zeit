defmodule NeuZeitWeb.WorkloadControllerTest do
  use NeuZeitWeb.ConnCase, async: true
  import NeuZeit.Fixtures
  alias NeuZeit.Catalog

  setup do
    term = term_fixture()

    attrs = %{
      course_component_id: component_fixture().id,
      teacher_id: teacher_fixture().id,
      cohort_ids: [cohort_fixture().id],
      week_mask: [1, 2],
      duration_slots: 1,
      contact_hours: "4"
    }

    %{term: term, attrs: attrs}
  end

  test "creates, reads, edits and deletes hours through a stable workload ID", c do
    created =
      post(c.conn, ~p"/api/terms/#{c.term}/workloads", workload: c.attrs) |> json_response(201)

    id = created["data"]["id"]
    assert created["data"]["cohort_ids"] == c.attrs.cohort_ids
    assert created["data"]["automatic_weeks"]
    assert length(Catalog.list_sessions(c.term.id)) == 2

    assert %{"data" => [%{"id" => ^id}]} =
             get(c.conn, ~p"/api/terms/#{c.term}/workloads") |> json_response(200)

    assert %{"data" => %{"id" => ^id}} =
             get(c.conn, ~p"/api/terms/#{c.term}/workloads/#{id}") |> json_response(200)

    assert %{"data" => %{"id" => ^id}} =
             put(c.conn, ~p"/api/terms/#{c.term}/workloads/#{id}",
               workload: %{contact_hours: "6"}
             )
             |> json_response(200)

    assert length(Catalog.list_sessions(c.term.id)) == 3
    assert response(delete(c.conn, ~p"/api/terms/#{c.term}/workloads/#{id}"), 204) == ""
    assert Catalog.list_sessions(c.term.id) == []
  end

  test "requires hours and rejects session mutation endpoints", c do
    assert post(c.conn, ~p"/api/terms/#{c.term}/workloads",
             workload: Map.delete(c.attrs, :contact_hours)
           )
           |> json_response(422)

    assert post(c.conn, ~p"/api/sessions", session: Map.put(c.attrs, :term_id, c.term.id))
           |> json_response(409)

    {:ok, :saved} = Catalog.save_workload(c.term.id, nil, c.attrs)
    [session | _] = Catalog.list_sessions(c.term.id)

    assert put(c.conn, ~p"/api/sessions/#{session}", session: %{duration_slots: 2})
           |> json_response(409)

    assert delete(c.conn, ~p"/api/sessions/#{session}") |> json_response(409)
    assert get(c.conn, ~p"/api/sessions/#{session}") |> json_response(200)
  end

  test "scopes workload IDs to their semester", c do
    {:ok, :saved} = Catalog.save_workload(c.term.id, nil, c.attrs)
    [row] = Catalog.list_workload(c.term.id)
    other = term_fixture()
    assert get(c.conn, ~p"/api/terms/#{other}/workloads/#{row.id}") |> json_response(404)

    assert put(c.conn, ~p"/api/terms/#{other}/workloads/#{row.id}",
             workload: %{contact_hours: "6"}
           )
           |> json_response(404)

    assert delete(c.conn, ~p"/api/terms/#{other}/workloads/#{row.id}") |> json_response(404)
    assert get(c.conn, "/api/terms/invalid/workloads") |> json_response(400)
  end
end
