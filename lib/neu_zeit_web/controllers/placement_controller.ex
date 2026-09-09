defmodule NeuZeitWeb.PlacementController do
  use NeuZeitWeb, :controller

  alias NeuZeit.Planning
  alias NeuZeitWeb.{ApiJSON, RequestParams}

  action_fallback NeuZeitWeb.FallbackController

  def index(conn, %{"plan_id" => plan_id}) do
    with :ok <- RequestParams.require_uuid(plan_id, "plan_id") do
      json(conn, %{data: ApiJSON.data(Planning.list_placements(plan_id))})
    end
  end

  def index(conn, _params) do
    json(conn, %{data: ApiJSON.data(Planning.list_placements())})
  end

  def create(conn, params) do
    with {:ok, placement} <- Planning.create_placement(params["placement"] || params) do
      conn
      |> put_status(:created)
      |> json(%{data: ApiJSON.data(placement)})
    end
  end

  def show(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, placement} <-
           RequestParams.fetch_not_found(fn -> Planning.get_placement!(id) end) do
      json(conn, %{data: ApiJSON.data(placement)})
    end
  end

  def update(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, placement} <-
           RequestParams.fetch_not_found(fn -> Planning.get_placement!(id) end),
         {:ok, placement} <-
           Planning.update_placement(placement, conn.body_params["placement"] || conn.body_params) do
      json(conn, %{data: ApiJSON.data(placement)})
    end
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, placement} <-
           RequestParams.fetch_not_found(fn -> Planning.get_placement!(id) end),
         {:ok, _placement} <- delete_placement(placement) do
      send_resp(conn, :no_content, "")
    end
  end

  defp delete_placement(placement) do
    Planning.delete_placement(placement)
  rescue
    Ecto.ConstraintError -> {:error, {:conflict, "Resource is referenced by other records"}}
  end
end
