defmodule NeuZeitWeb.HealthController do
  use NeuZeitWeb, :controller

  require Logger

  # Container health checks wait 3 seconds. Answer before that, so a slow
  # database reports 503 instead of a timed-out check.
  @query_timeout_ms 1_000

  @doc """
  Reports whether the application can query PostgreSQL.

  Answers 200 when the query succeeds and 503 when it fails.
  """
  def show(conn, _params) do
    case NeuZeit.Repo.query("SELECT 1", [], timeout: @query_timeout_ms) do
      {:ok, _result} ->
        json(conn, %{status: "ok", database: "ok"})

      {:error, error} ->
        Logger.warning("Health check failed: database unavailable: #{Exception.message(error)}")

        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "error", database: "unavailable"})
    end
  end
end
