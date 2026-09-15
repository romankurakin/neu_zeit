defmodule NeuZeitWeb.TeachingTypeController do
  use NeuZeitWeb, :controller
  alias NeuZeit.Catalog
  alias NeuZeitWeb.{ApiJSON, RequestParams}
  action_fallback NeuZeitWeb.FallbackController

  def index(conn, _params), do: json(conn, %{data: ApiJSON.data(Catalog.list_teaching_types())})

  def show(conn, %{"id" => id}) do
    with {:ok, type} <- RequestParams.fetch_not_found(fn -> Catalog.get_teaching_type!(id) end) do
      json(conn, %{data: ApiJSON.data(type)})
    end
  end

  def create(conn, params) do
    with {:ok, type} <- Catalog.create_teaching_type(params["teaching_type"] || params) do
      conn |> put_status(:created) |> json(%{data: ApiJSON.data(type)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, type} <- RequestParams.fetch_not_found(fn -> Catalog.get_teaching_type!(id) end),
         {:ok, type} <- Catalog.update_teaching_type(type, params["teaching_type"] || params) do
      json(conn, %{data: ApiJSON.data(type)})
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, type} <- RequestParams.fetch_not_found(fn -> Catalog.get_teaching_type!(id) end),
         {:ok, _type} <- Catalog.delete_teaching_type(type) do
      send_resp(conn, :no_content, "")
    end
  end
end
