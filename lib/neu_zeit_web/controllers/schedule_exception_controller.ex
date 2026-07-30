defmodule NeuZeitWeb.ScheduleExceptionController do
  use NeuZeitWeb, :controller

  alias NeuZeit.Planning
  alias NeuZeitWeb.{ApiJSON, RequestParams}

  action_fallback NeuZeitWeb.FallbackController

  def index(conn, _params) do
    json(conn, %{data: ApiJSON.data(Planning.list_schedule_exceptions())})
  end

  def create(conn, params) do
    with {:ok, exception} <-
           Planning.create_schedule_exception(params["schedule_exception"] || params) do
      conn
      |> put_status(:created)
      |> json(%{data: ApiJSON.data(exception)})
    end
  end

  def show(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, exception} <-
           RequestParams.fetch_not_found(fn -> Planning.get_schedule_exception!(id) end) do
      json(conn, %{data: ApiJSON.data(exception)})
    end
  end

  def update(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, exception} <-
           RequestParams.fetch_not_found(fn -> Planning.get_schedule_exception!(id) end),
         {:ok, exception} <-
           Planning.update_schedule_exception(
             exception,
             conn.body_params["schedule_exception"] || conn.body_params
           ) do
      json(conn, %{data: ApiJSON.data(exception)})
    end
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, exception} <-
           RequestParams.fetch_not_found(fn -> Planning.get_schedule_exception!(id) end),
         {:ok, _exception} <- delete_schedule_exception(exception) do
      send_resp(conn, :no_content, "")
    end
  end

  defp delete_schedule_exception(exception) do
    Planning.delete_schedule_exception(exception)
  rescue
    Ecto.ConstraintError -> {:error, {:conflict, "Resource is referenced by other records"}}
  end
end
