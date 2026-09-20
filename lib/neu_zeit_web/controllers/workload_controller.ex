defmodule NeuZeitWeb.WorkloadController do
  use NeuZeitWeb, :controller

  alias NeuZeit.Catalog
  alias NeuZeit.Catalog.{Workload, Workloads}
  alias NeuZeitWeb.{ApiJSON, RequestParams}

  action_fallback NeuZeitWeb.FallbackController

  def index(conn, %{"term_id" => term_id}) do
    with :ok <- term_exists(term_id) do
      term = Catalog.get_term!(term_id)
      json(conn, %{data: Enum.map(Workloads.list(term_id), &workload_data(&1, term))})
    end
  end

  def show(conn, %{"term_id" => term_id, "id" => id}) do
    with {:ok, row} <- fetch(term_id, id) do
      json(conn, %{data: workload_data(row, Catalog.get_term!(term_id))})
    end
  end

  def create(conn, %{"term_id" => term_id} = params) do
    with :ok <- term_exists(term_id),
         {:ok, requirement} <-
           Workloads.save_requirement(term_id, nil, params["workload"] || params),
         {:ok, row} <- fetch(term_id, requirement.id) do
      conn
      |> put_status(:created)
      |> json(%{data: workload_data(row, Catalog.get_term!(term_id))})
    end
  end

  def update(conn, %{"term_id" => term_id, "id" => id} = params) do
    with {:ok, row} <- fetch(term_id, id),
         {:ok, requirement} <-
           Workloads.save_requirement(term_id, row, params["workload"] || params),
         {:ok, updated} <- fetch(term_id, requirement.id) do
      json(conn, %{data: workload_data(updated, Catalog.get_term!(term_id))})
    end
  end

  def delete(conn, %{"term_id" => term_id, "id" => id}) do
    with {:ok, row} <- fetch(term_id, id),
         {:ok, :deleted} <- Workloads.delete(term_id, row) do
      send_resp(conn, :no_content, "")
    end
  end

  defp workload_data(row, term) do
    row.requirement
    |> Map.take(Workload.__schema__(:fields))
    |> ApiJSON.data()
    |> Map.put(:cohort_ids, row.requirement.cohort_ids)
    |> Map.merge(
      ApiJSON.data(%{
        required_hours: row.requirement.contact_hours,
        planned_hours: Workloads.planned_hours(row, term),
        meeting_count: Workloads.meeting_count(row),
        series_count: Workloads.series_count(row)
      })
    )
  end

  defp fetch(term_id, id) do
    with :ok <- term_exists(term_id),
         :ok <- RequestParams.require_uuid(id) do
      case Enum.find(Workloads.list(term_id), &(&1.id == id)) do
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
