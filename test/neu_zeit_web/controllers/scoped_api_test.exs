defmodule NeuZeitWeb.ScopedApiTest do
  @moduledoc """
  Tests API filters and reports used by the administrator interface.
  """
  use NeuZeitWeb.ConnCase, async: true

  alias NeuZeit.{Catalog, Planning}

  setup %{conn: conn} do
    conn = put_req_header(conn, "accept", "application/json")

    {:ok, term} =
      Catalog.create_term(%{
        "name" => "Wintersemester 2026/27",
        "starts_on" => "2026-09-07",
        "ends_on" => "2026-12-20"
      })

    {:ok, other_term} =
      Catalog.create_term(%{
        "name" => "Sommer 2027",
        "starts_on" => "2027-02-01",
        "ends_on" => "2027-05-30"
      })

    {:ok, building} = Catalog.create_building(%{"name" => "Hauptgebäude"})
    {:ok, room} = Catalog.create_room(%{"building_id" => building.id, "name" => "101"})
    {:ok, cohort} = Catalog.create_cohort(%{"name" => "WI-1"})
    {:ok, teacher} = Catalog.create_teacher(%{"name" => "Anna Weber"})
    {:ok, other_teacher} = Catalog.create_teacher(%{"name" => "Erik Hoffmann"})
    {:ok, course} = Catalog.create_course(%{"code" => "INF110", "title" => "P"})

    {:ok, component} =
      Catalog.create_course_component(%{
        "course_id" => course.id,
        "kind" => "lecture",
        "allowed_room_ids" => [room.id]
      })

    base = %{
      "course_component_id" => component.id,
      "week_mask" => [1, 2],
      "duration_slots" => 1,
      "cohort_ids" => [cohort.id]
    }

    {:ok, here} =
      NeuZeit.Fixtures.create_session(
        Map.merge(base, %{"term_id" => term.id, "teacher_id" => teacher.id})
      )

    {:ok, _mine_other_teacher} =
      NeuZeit.Fixtures.create_session(
        Map.merge(base, %{"term_id" => term.id, "teacher_id" => other_teacher.id})
      )

    {:ok, elsewhere} =
      NeuZeit.Fixtures.create_session(
        Map.merge(base, %{"term_id" => other_term.id, "teacher_id" => teacher.id})
      )

    {:ok, plan} = Planning.create_plan(%{"term_id" => term.id, "name" => "Entwurf 1"})

    {:ok, placement} =
      Planning.create_placement(%{
        "plan_id" => plan.id,
        "session_id" => here.id,
        "room_id" => room.id,
        "day" => 1,
        "slot" => 1
      })

    %{
      conn: conn,
      term: term,
      other_term: other_term,
      plan: plan,
      here: here,
      elsewhere: elsewhere,
      teacher: teacher,
      placement: placement,
      course: course
    }
  end

  defp ids(conn), do: json_response(conn, 200)["data"] |> Enum.map(& &1["id"])

  describe "sessions" do
    test "unscoped still returns every term's sessions", %{conn: conn} = ctx do
      returned = ids(get(conn, ~p"/api/sessions"))
      assert ctx.here.id in returned
      assert ctx.elsewhere.id in returned
    end

    test "term_id narrows to one term", %{conn: conn} = ctx do
      returned = ids(get(conn, ~p"/api/sessions?term_id=#{ctx.term.id}"))
      assert ctx.here.id in returned
      refute ctx.elsewhere.id in returned
    end

    test "the screen's filters work as query parameters", %{conn: conn} = ctx do
      returned =
        ids(get(conn, ~p"/api/sessions?term_id=#{ctx.term.id}&teacher_id=#{ctx.teacher.id}"))

      assert returned == [ctx.here.id]
    end

    test "a malformed term_id is refused rather than ignored", %{conn: conn} do
      assert get(conn, ~p"/api/sessions?term_id=not-a-uuid").status in [400, 422]
    end
  end

  describe "plans, placements and exceptions" do
    test "plans can be scoped to a term", %{conn: conn} = ctx do
      assert ids(get(conn, ~p"/api/plans?term_id=#{ctx.term.id}")) == [ctx.plan.id]
      assert ids(get(conn, ~p"/api/plans?term_id=#{ctx.other_term.id}")) == []
    end

    test "placements can be scoped to a plan", %{conn: conn} = ctx do
      assert ids(get(conn, ~p"/api/placements?plan_id=#{ctx.plan.id}")) == [ctx.placement.id]
    end

    test "exceptions can be scoped to a term", %{conn: conn} = ctx do
      assert ids(get(conn, ~p"/api/schedule_exceptions?term_id=#{ctx.term.id}")) == []
    end
  end

  describe "term coverage" do
    test "reports every course taught in the term", %{conn: conn} = ctx do
      body = json_response(get(conn, ~p"/api/terms/#{ctx.term.id}/coverage"), 200)

      assert [row] = body["data"]
      assert row["code"] == "INF110"
      assert row["required_hours"] == 6.0
      assert row["status"] == "ok"
    end
  end

  describe "quality" do
    test "returns rule checks for a plan", %{conn: conn} = ctx do
      body = json_response(get(conn, ~p"/api/plans/#{ctx.plan.id}/quality"), 200)

      assert is_list(body["data"]["cohorts"])
      assert is_list(body["data"]["teachers"])
      # The summary verdicts travel in meta, as the other plan endpoints do.
      assert body["meta"]["gaps"] == 0
      assert Map.has_key?(body["meta"], "saturday")
    end

    test "a malformed plan id is refused", %{conn: conn} do
      assert get(conn, ~p"/api/plans/not-a-uuid/quality").status in [400, 422]
    end
  end

  describe "draft projection" do
    test "occurrences default to the published plan", %{conn: conn} = ctx do
      body = json_response(get(conn, ~p"/api/terms/#{ctx.term.id}/occurrences"), 200)

      # Nothing is published yet, so the projection is empty by design.
      assert body["data"] == []
      assert body["meta"]["active_plan_id"] == nil
    end

    test "a plan_id projects that plan instead, draft included", %{conn: conn} = ctx do
      body =
        json_response(
          get(conn, ~p"/api/terms/#{ctx.term.id}/occurrences?plan_id=#{ctx.plan.id}"),
          200
        )

      assert length(body["data"]) > 0
      assert body["meta"]["plan_status"] == "draft"
      assert body["meta"]["exceptions_applied"] == false
    end

    test "a plan from another term is not found", %{conn: conn} = ctx do
      {:ok, foreign} =
        Planning.create_plan(%{"term_id" => ctx.other_term.id, "name" => "Foreign"})

      assert get(conn, ~p"/api/terms/#{ctx.term.id}/occurrences?plan_id=#{foreign.id}").status ==
               404
    end
  end
end
