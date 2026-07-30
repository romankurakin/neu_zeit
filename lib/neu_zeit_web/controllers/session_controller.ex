defmodule NeuZeitWeb.SessionController do
  use NeuZeitWeb, :controller

  alias NeuZeit.Catalog
  alias NeuZeitWeb.{ApiJSON, RequestParams}

  action_fallback NeuZeitWeb.FallbackController

  def index(conn, _params) do
    json(conn, %{data: ApiJSON.data(Catalog.list_sessions())})
  end

  def create(conn, params) do
    with {:ok, session} <- Catalog.create_session(params["session"] || params) do
      conn
      |> put_status(:created)
      |> json(%{data: ApiJSON.data(session)})
    end
  end

  def show(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, session} <- RequestParams.fetch_not_found(fn -> Catalog.get_session!(id) end) do
      json(conn, %{data: ApiJSON.data(session)})
    end
  end

  def update(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, session} <- RequestParams.fetch_not_found(fn -> Catalog.get_session!(id) end),
         {:ok, session} <-
           Catalog.update_session(session, conn.body_params["session"] || conn.body_params) do
      json(conn, %{data: ApiJSON.data(session)})
    end
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, session} <- RequestParams.fetch_not_found(fn -> Catalog.get_session!(id) end),
         {:ok, _session} <- delete_session(session) do
      send_resp(conn, :no_content, "")
    end
  end

  defp delete_session(session) do
    Catalog.delete_session(session)
  rescue
    Ecto.ConstraintError -> {:error, {:conflict, "Resource is referenced by other records"}}
  end
end
