defmodule NeuZeitWeb.TeacherController do
  use NeuZeitWeb, :controller

  alias NeuZeit.Catalog
  alias NeuZeitWeb.{ApiJSON, RequestParams}

  action_fallback NeuZeitWeb.FallbackController

  def index(conn, _params) do
    json(conn, %{data: ApiJSON.data(Catalog.list_teachers())})
  end

  def create(conn, params) do
    with {:ok, teacher} <- Catalog.create_teacher(params["teacher"] || params) do
      conn
      |> put_status(:created)
      |> json(%{data: ApiJSON.data(teacher)})
    end
  end

  def show(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, teacher} <- RequestParams.fetch_not_found(fn -> Catalog.get_teacher!(id) end) do
      json(conn, %{data: ApiJSON.data(teacher)})
    end
  end

  def update(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, teacher} <- RequestParams.fetch_not_found(fn -> Catalog.get_teacher!(id) end),
         {:ok, teacher} <-
           Catalog.update_teacher(teacher, conn.body_params["teacher"] || conn.body_params) do
      json(conn, %{data: ApiJSON.data(teacher)})
    end
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, teacher} <- RequestParams.fetch_not_found(fn -> Catalog.get_teacher!(id) end),
         {:ok, _teacher} <- delete_teacher(teacher) do
      send_resp(conn, :no_content, "")
    end
  end

  defp delete_teacher(teacher) do
    Catalog.delete_teacher(teacher)
  rescue
    Ecto.ConstraintError -> {:error, {:conflict, "Resource is referenced by other records"}}
  end
end
