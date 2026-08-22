defmodule NeuZeitWeb.ScheduleController do
  use NeuZeitWeb, :controller

  alias NeuZeit.Planning
  alias NeuZeitWeb.ApiJSON
  alias NeuZeitWeb.RequestParams

  action_fallback NeuZeitWeb.FallbackController

  def occurrences(conn, %{"term_id" => term_id}) do
    with :ok <- RequestParams.require_uuid(term_id, "term_id"),
         {:ok, projection} <-
           RequestParams.fetch_not_found(fn -> Planning.project_active_term(term_id) end) do
      json(conn, %{
        data: ApiJSON.data(projection.occurrences),
        meta: %{
          unplaced_session_ids: projection.unplaced_session_ids,
          active_plan_id: projection.active_plan_id
        }
      })
    end
  end
end
