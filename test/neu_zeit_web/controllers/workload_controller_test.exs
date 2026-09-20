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
    refute created["data"]["automatic_weeks"]
    assert created["data"]["required_hours"] == "4"
    assert Decimal.equal?(Decimal.new(created["data"]["planned_hours"]), 4)
    assert created["data"]["meeting_count"] == 2
    assert created["data"]["series_count"] == 1

    refute Enum.any?(
             [
               "count",
               "academic_hour_minutes",
               "course_component",
               "teacher",
               "slot_profile",
               "cohorts"
             ],
             &Map.has_key?(created["data"], &1)
           )

    assert length(Catalog.list_sessions(c.term.id)) == 1

    assert %{"data" => [%{"id" => ^id}]} =
             get(c.conn, ~p"/api/terms/#{c.term}/workloads") |> json_response(200)

    assert %{"data" => %{"id" => ^id}} =
             get(c.conn, ~p"/api/terms/#{c.term}/workloads/#{id}") |> json_response(200)

    assert %{"data" => %{"id" => ^id}} =
             put(c.conn, ~p"/api/terms/#{c.term}/workloads/#{id}",
               workload: %{contact_hours: "6"}
             )
             |> json_response(200)

    assert length(Catalog.list_sessions(c.term.id)) == 2
    assert response(delete(c.conn, ~p"/api/terms/#{c.term}/workloads/#{id}"), 204) == ""
    assert Catalog.list_sessions(c.term.id) == []
  end

  test "all responses preserve 45 required hours and expose the rounded realization", c do
    attrs = Map.merge(c.attrs, %{contact_hours: "45", week_mask: Enum.to_list(1..15)})

    created =
      post(c.conn, ~p"/api/terms/#{c.term}/workloads", workload: attrs) |> json_response(201)

    id = created["data"]["id"]
    shown = get(c.conn, ~p"/api/terms/#{c.term}/workloads/#{id}") |> json_response(200)
    listed = get(c.conn, ~p"/api/terms/#{c.term}/workloads") |> json_response(200)

    for data <- [created["data"], shown["data"], hd(listed["data"])] do
      assert Decimal.equal?(Decimal.new(data["contact_hours"]), 45)
      assert Decimal.equal?(Decimal.new(data["required_hours"]), 45)
      assert Decimal.equal?(Decimal.new(data["planned_hours"]), 46)
      assert data["meeting_count"] == 23
      assert data["series_count"] == 2
      assert data["rounding_mode"] == "up"
      assert data["remainder_parity"] == "odd"
    end

    changed =
      put(c.conn, ~p"/api/terms/#{c.term}/workloads/#{id}", workload: %{rounding_mode: "down"})
      |> json_response(200)

    assert Decimal.equal?(Decimal.new(changed["data"]["required_hours"]), 45)
    assert Decimal.equal?(Decimal.new(changed["data"]["planned_hours"]), 44)
    assert changed["data"]["meeting_count"] == 22
    assert changed["data"]["rounding_mode"] == "down"
    assert {:ok, :ready} = Catalog.Workloads.prepare(c.term.id)
    reloaded = get(c.conn, ~p"/api/terms/#{c.term}/workloads/#{id}") |> json_response(200)
    assert reloaded["data"]["planned_hours"] == changed["data"]["planned_hours"]
  end

  test "rejects invalid planning policies and ignores a requested legacy mode", c do
    for policy <- [%{rounding_mode: "nearest"}, %{remainder_parity: "arbitrary"}] do
      assert post(c.conn, ~p"/api/terms/#{c.term}/workloads",
               workload: Map.merge(c.attrs, policy)
             )
             |> json_response(422)
    end

    created =
      post(c.conn, ~p"/api/terms/#{c.term}/workloads",
        workload: Map.put(c.attrs, :automatic_weeks, true)
      )
      |> json_response(201)

    refute created["data"]["automatic_weeks"]
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
