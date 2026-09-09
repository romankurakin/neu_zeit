defmodule NeuZeitWeb.CourseController do
  use NeuZeitWeb, :controller

  alias NeuZeit.Catalog
  alias NeuZeitWeb.{ApiJSON, RequestParams}

  action_fallback NeuZeitWeb.FallbackController

  def index(conn, %{"locale" => locale}) when is_binary(locale) do
    json(conn, %{data: ApiJSON.data(Catalog.list_courses(locale))})
  end

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

  def create_translation(conn, %{"course_id" => course_id}) do
    attrs =
      (conn.body_params["course_translation"] || conn.body_params)
      |> Map.put("course_id", course_id)

    with :ok <- RequestParams.require_uuid(course_id, "course_id"),
         {:ok, _course} <- RequestParams.fetch_not_found(fn -> Catalog.get_course!(course_id) end),
         {:ok, translation} <- Catalog.create_course_translation(attrs) do
      conn
      |> put_status(:created)
      |> json(%{data: ApiJSON.data(translation)})
    end
  end

  def translations(conn, %{"course_id" => course_id}) do
    with :ok <- RequestParams.require_uuid(course_id, "course_id"),
         {:ok, _course} <- RequestParams.fetch_not_found(fn -> Catalog.get_course!(course_id) end) do
      json(conn, %{data: ApiJSON.data(Catalog.list_course_translations(course_id))})
    end
  end

  def update_translation(conn, %{"course_id" => course_id, "locale" => locale}) do
    attrs = conn.body_params["course_translation"] || conn.body_params

    with :ok <- RequestParams.require_uuid(course_id, "course_id"),
         {:ok, translation} <- fetch_translation(course_id, locale),
         {:ok, translation} <- Catalog.update_course_translation(translation, attrs) do
      json(conn, %{data: ApiJSON.data(translation)})
    end
  end

  def delete_translation(conn, %{"course_id" => course_id, "locale" => locale}) do
    with :ok <- RequestParams.require_uuid(course_id, "course_id"),
         {:ok, translation} <- fetch_translation(course_id, locale),
         {:ok, _translation} <- Catalog.delete_course_translation(translation) do
      send_resp(conn, :no_content, "")
    end
  end

  defp fetch_translation(course_id, locale) do
    case Catalog.get_course_translation(course_id, locale) do
      nil -> {:error, :not_found}
      translation -> {:ok, translation}
    end
  end

  defp delete_course(course) do
    Catalog.delete_course(course)
  rescue
    Ecto.ConstraintError -> {:error, {:conflict, "Resource is referenced by other records"}}
  end
end
