defmodule NeuZeitWeb.CourseComponentController do
  use NeuZeitWeb, :controller

  alias NeuZeit.Catalog
  alias NeuZeitWeb.{ApiJSON, RequestParams}

  action_fallback NeuZeitWeb.FallbackController

  def index(conn, _params) do
    json(conn, %{data: ApiJSON.data(Catalog.list_course_components())})
  end

  def create(conn, params) do
    with {:ok, component} <- Catalog.create_course_component(params["course_component"] || params) do
      conn
      |> put_status(:created)
      |> json(%{data: ApiJSON.data(component)})
    end
  end

  def show(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, component} <-
           RequestParams.fetch_not_found(fn -> Catalog.get_course_component!(id) end) do
      json(conn, %{data: ApiJSON.data(component)})
    end
  end

  def update(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, component} <-
           RequestParams.fetch_not_found(fn -> Catalog.get_course_component!(id) end),
         {:ok, component} <-
           Catalog.update_course_component(
             component,
             conn.body_params["course_component"] || conn.body_params
           ) do
      json(conn, %{data: ApiJSON.data(component)})
    end
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, component} <-
           RequestParams.fetch_not_found(fn -> Catalog.get_course_component!(id) end),
         {:ok, _component} <- delete_course_component(component) do
      send_resp(conn, :no_content, "")
    end
  end

  defp delete_course_component(component) do
    Catalog.delete_course_component(component)
  rescue
    Ecto.ConstraintError -> {:error, {:conflict, "Resource is referenced by other records"}}
  end
end
