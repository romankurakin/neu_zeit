defmodule NeuZeitWeb.CohortController do
  use NeuZeitWeb, :controller

  alias NeuZeit.Catalog
  alias NeuZeitWeb.{ApiJSON, RequestParams}

  action_fallback NeuZeitWeb.FallbackController

  def index(conn, _params) do
    json(conn, %{data: ApiJSON.data(Catalog.list_cohorts())})
  end

  def create(conn, params) do
    with {:ok, cohort} <- Catalog.create_cohort(params["cohort"] || params) do
      conn
      |> put_status(:created)
      |> json(%{data: ApiJSON.data(cohort)})
    end
  end

  def show(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, cohort} <- RequestParams.fetch_not_found(fn -> Catalog.get_cohort!(id) end) do
      json(conn, %{data: ApiJSON.data(cohort)})
    end
  end

  def update(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, cohort} <- RequestParams.fetch_not_found(fn -> Catalog.get_cohort!(id) end),
         {:ok, cohort} <-
           Catalog.update_cohort(cohort, conn.body_params["cohort"] || conn.body_params) do
      json(conn, %{data: ApiJSON.data(cohort)})
    end
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, cohort} <- RequestParams.fetch_not_found(fn -> Catalog.get_cohort!(id) end),
         {:ok, _cohort} <- delete_cohort(cohort) do
      send_resp(conn, :no_content, "")
    end
  end

  defp delete_cohort(cohort) do
    Catalog.delete_cohort(cohort)
  rescue
    Ecto.ConstraintError -> {:error, {:conflict, "Resource is referenced by other records"}}
  end
end
