defmodule NeuZeitWeb.RoomController do
  use NeuZeitWeb, :controller

  alias NeuZeit.Catalog
  alias NeuZeitWeb.{ApiJSON, RequestParams}

  action_fallback NeuZeitWeb.FallbackController

  def index(conn, _params) do
    json(conn, %{data: ApiJSON.data(Catalog.list_rooms())})
  end

  def create(conn, params) do
    with {:ok, room} <- Catalog.create_room(params["room"] || params) do
      conn
      |> put_status(:created)
      |> json(%{data: ApiJSON.data(room)})
    end
  end

  def show(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, room} <- RequestParams.fetch_not_found(fn -> Catalog.get_room!(id) end) do
      json(conn, %{data: ApiJSON.data(room)})
    end
  end

  def update(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, room} <- RequestParams.fetch_not_found(fn -> Catalog.get_room!(id) end),
         {:ok, room} <- Catalog.update_room(room, conn.body_params["room"] || conn.body_params) do
      json(conn, %{data: ApiJSON.data(room)})
    end
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, room} <- RequestParams.fetch_not_found(fn -> Catalog.get_room!(id) end),
         {:ok, _room} <- delete_room(room) do
      send_resp(conn, :no_content, "")
    end
  end

  defp delete_room(room) do
    Catalog.delete_room(room)
  rescue
    Ecto.ConstraintError -> {:error, {:conflict, "Resource is referenced by other records"}}
  end
end
