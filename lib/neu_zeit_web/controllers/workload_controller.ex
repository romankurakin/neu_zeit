defmodule NeuZeitWeb.WorkloadController do
  use NeuZeitWeb, :controller

  alias NeuZeit.Catalog
  alias NeuZeit.Catalog.Workload
  alias NeuZeitWeb.{ApiJSON, RequestParams}

  action_fallback NeuZeitWeb.FallbackController

  def index(conn, %{"term_id" => term_id}) do
    with :ok <- term_exists(term_id) do
      json(conn, %{data: Enum.map(Workload.list(term_id), &workload_data(&1.requirement))})
    end
  end

  def show(conn, %{"term_id" => term_id, "id" => id}) do
    with {:ok, row} <- fetch(term_id, id) do
      json(conn, %{data: workload_data(row.requirement)})
    end
  end

  def create(conn, %{"term_id" => term_id} = params) do
    with :ok <- term_exists(term_id),
         {:ok, requirement} <-
           Workload.save_requirement(term_id, nil, params["workload"] || params) do
      conn |> put_status(:created) |> json(%{data: workload_data(requirement)})
    end
  end

  def update(conn, %{"term_id" => term_id, "id" => id} = params) do
    with {:ok, row} <- fetch(term_id, id),
         {:ok, requirement} <-
           Workload.save_requirement(term_id, row, params["workload"] || params) do
      json(conn, %{data: workload_data(requirement)})
    end
  end

  def delete(conn, %{"term_id" => term_id, "id" => id}) do
    with {:ok, row} <- fetch(term_id, id),
         {:ok, :deleted} <- Workload.delete(term_id, row) do
      send_resp(conn, :no_content, "")
    end
  end

  defp workload_data(requirement) do
    requirement
    |> ApiJSON.data()
    |> Map.drop([:cohorts])
    |> Map.put(:cohort_ids, requirement.cohort_ids)
  end

  defp fetch(term_id, id) do
    with :ok <- term_exists(term_id),
         :ok <- RequestParams.require_uuid(id) do
      case Enum.find(Workload.list(term_id), &(&1.id == id)) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end
  end

  defp term_exists(id) do
    with :ok <- RequestParams.require_uuid(id, "term_id"),
         {:ok, _term} <- RequestParams.fetch_not_found(fn -> Catalog.get_term!(id) end),
         do: :ok
  end
end
