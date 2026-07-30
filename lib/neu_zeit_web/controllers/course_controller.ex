defmodule NeuZeitWeb.CourseController do
  use NeuZeitWeb, :controller

  alias NeuZeit.Catalog
  alias NeuZeitWeb.{ApiJSON, RequestParams}

  action_fallback NeuZeitWeb.FallbackController

  def index(conn, _params) do
    json(conn, %{data: ApiJSON.data(Catalog.list_courses())})
  end

  def create(conn, params) do
    with {:ok, course} <- Catalog.create_course(params["course"] || params) do
      conn
      |> put_status(:created)
      |> json(%{data: ApiJSON.data(course)})
    end
  end

  def show(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, course} <- RequestParams.fetch_not_found(fn -> Catalog.get_course!(id) end) do
      json(conn, %{data: ApiJSON.data(course)})
    end
  end

  def update(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, course} <- RequestParams.fetch_not_found(fn -> Catalog.get_course!(id) end),
         {:ok, course} <-
           Catalog.update_course(course, conn.body_params["course"] || conn.body_params) do
      json(conn, %{data: ApiJSON.data(course)})
    end
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, course} <- RequestParams.fetch_not_found(fn -> Catalog.get_course!(id) end),
         {:ok, _course} <- delete_course(course) do
      send_resp(conn, :no_content, "")
    end
  end

  defp delete_course(course) do
    Catalog.delete_course(course)
  rescue
    Ecto.ConstraintError -> {:error, {:conflict, "Resource is referenced by other records"}}
  end
end
