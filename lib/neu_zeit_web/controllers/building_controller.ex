defmodule NeuZeitWeb.BuildingController do
  use NeuZeitWeb, :controller

  alias NeuZeit.Catalog
  alias NeuZeitWeb.{ApiJSON, RequestParams}

  action_fallback NeuZeitWeb.FallbackController

  def index(conn, _params) do
    json(conn, %{data: ApiJSON.data(Catalog.list_buildings())})
  end

  def create(conn, params) do
    with {:ok, building} <- Catalog.create_building(params["building"] || params) do
      conn
      |> put_status(:created)
      |> json(%{data: ApiJSON.data(building)})
    end
  end

  def show(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, building} <- RequestParams.fetch_not_found(fn -> Catalog.get_building!(id) end) do
      json(conn, %{data: ApiJSON.data(building)})
    end
  end

  def update(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, building} <- RequestParams.fetch_not_found(fn -> Catalog.get_building!(id) end),
         {:ok, building} <-
           Catalog.update_building(building, conn.body_params["building"] || conn.body_params) do
      json(conn, %{data: ApiJSON.data(building)})
    end
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, building} <- RequestParams.fetch_not_found(fn -> Catalog.get_building!(id) end),
         {:ok, _building} <- delete_building(building) do
      send_resp(conn, :no_content, "")
    end
  end

  defp delete_building(building) do
    Catalog.delete_building(building)
  rescue
    Ecto.ConstraintError -> {:error, {:conflict, "Resource is referenced by other records"}}
  end
end
