defmodule NeuZeitWeb.ScheduleController do
  use NeuZeitWeb, :controller

  alias NeuZeit.Planning
  alias NeuZeitWeb.ApiJSON
  alias NeuZeitWeb.RequestParams

  action_fallback NeuZeitWeb.FallbackController

  @doc """
  Returns dated occurrences for a term.

  Without `plan_id`, uses the active plan. An explicit `plan_id` also permits
  review of a draft.
  """
  def occurrences(conn, %{"term_id" => term_id, "plan_id" => plan_id}) do
    with :ok <- RequestParams.require_uuid(term_id, "term_id"),
         :ok <- RequestParams.require_uuid(plan_id, "plan_id"),
         {:ok, projection} <-
           RequestParams.fetch_not_found(fn -> Planning.project_plan(plan_id) end),
         :ok <- ensure_same_term(projection, term_id) do
      json(conn, %{
        data: ApiJSON.data(projection.occurrences),
        meta: %{
          unplaced_session_ids: projection.unplaced_session_ids,
          plan_id: projection.plan.id,
          plan_status: projection.plan.status,
          exceptions_applied: projection.exceptions_applied
        }
      })
    end
  end

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

  defp ensure_same_term(%{plan: %{term_id: term_id}}, term_id), do: :ok
  defp ensure_same_term(_projection, _term_id), do: {:error, :not_found}
end
