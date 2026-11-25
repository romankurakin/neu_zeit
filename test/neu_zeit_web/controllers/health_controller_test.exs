defmodule NeuZeitWeb.HealthControllerTest do
  # Async keeps the SQL sandbox private to the test process. The 503 test
  # depends on that.
  use NeuZeitWeb.ConnCase, async: true

  import ExUnit.CaptureLog

  test "GET /health reports the database as reachable" do
    conn = build_conn() |> get(~p"/health")

    assert json_response(conn, 200) == %{"status" => "ok", "database" => "ok"}
  end

  test "GET /health accepts requests that prefer HTML" do
    conn =
      build_conn()
      |> put_req_header("accept", "text/html")
      |> get(~p"/health")

    assert json_response(conn, 200) == %{"status" => "ok", "database" => "ok"}
  end

  test "GET /health answers 503 when the repository has no connection" do
    parent = self()

    # A plain spawned process has no access to the test's sandbox, so the
    # repository refuses it a connection, as it does while PostgreSQL is down.
    log =
      capture_log(fn ->
        spawn(fn -> send(parent, {:health, build_conn() |> get(~p"/health")}) end)
        assert_receive {:health, conn}, 5_000

        assert json_response(conn, 503) == %{"status" => "error", "database" => "unavailable"}
      end)

    assert log =~ "Health check failed: database unavailable"
  end
end
