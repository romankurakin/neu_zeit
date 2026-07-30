defmodule NeuZeitWeb.TermController do
  use NeuZeitWeb, :controller

  alias NeuZeit.Catalog
  alias NeuZeitWeb.{ApiJSON, RequestParams}

  action_fallback NeuZeitWeb.FallbackController

  def index(conn, _params) do
    json(conn, %{data: ApiJSON.data(Catalog.list_terms())})
  end

  def create(conn, params) do
    with {:ok, term} <- Catalog.create_term(params["term"] || params) do
      conn
      |> put_status(:created)
      |> json(%{data: ApiJSON.data(term)})
    end
  end

  def show(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, term} <- RequestParams.fetch_not_found(fn -> Catalog.get_term!(id) end) do
      json(conn, %{data: ApiJSON.data(term)})
    end
  end

  def update(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, term} <- RequestParams.fetch_not_found(fn -> Catalog.get_term!(id) end),
         {:ok, term} <- Catalog.update_term(term, conn.body_params["term"] || conn.body_params) do
      json(conn, %{data: ApiJSON.data(term)})
    end
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, term} <- RequestParams.fetch_not_found(fn -> Catalog.get_term!(id) end),
         {:ok, _term} <- delete_term(term) do
      send_resp(conn, :no_content, "")
    end
  end

  def add_excluded_date(conn, %{"term_id" => id}) do
    with :ok <- RequestParams.require_uuid(id, "term_id"),
         {:ok, date} <- parse_date(conn.body_params["date"]),
         {:ok, term} <- RequestParams.fetch_not_found(fn -> Catalog.get_term!(id) end),
         {:ok, term} <- Catalog.add_excluded_date(term, date) do
      json(conn, %{data: ApiJSON.data(term)})
    end
  end

  def remove_excluded_date(conn, %{"term_id" => id, "date" => date}) do
    with :ok <- RequestParams.require_uuid(id, "term_id"),
         {:ok, date} <- parse_date(date),
         {:ok, term} <- RequestParams.fetch_not_found(fn -> Catalog.get_term!(id) end),
         {:ok, term} <- Catalog.remove_excluded_date(term, date) do
      json(conn, %{data: ApiJSON.data(term)})
    end
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, {:bad_request, "date must be an ISO 8601 date"}}
    end
  end

  defp parse_date(_value), do: {:error, {:bad_request, "date must be an ISO 8601 date"}}

  defp delete_term(term) do
    Catalog.delete_term(term)
  rescue
    Ecto.ConstraintError -> {:error, {:conflict, "Resource is referenced by other records"}}
  end
end
