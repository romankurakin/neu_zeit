defmodule NeuZeitWeb.PlanController do
  use NeuZeitWeb, :controller

  alias NeuZeit.Planning
  alias NeuZeitWeb.{ApiJSON, RequestParams}

  action_fallback NeuZeitWeb.FallbackController

  def index(conn, %{"term_id" => term_id}) do
    with :ok <- RequestParams.require_uuid(term_id, "term_id") do
      json(conn, %{data: ApiJSON.data(Planning.list_plans(term_id))})
    end
  end

  def index(conn, _params) do
    json(conn, %{data: ApiJSON.data(Planning.list_plans())})
  end

  @doc """
  Returns plan quality metrics for groups, teachers, sequences and rooms.
  """
  def quality(conn, %{"plan_id" => plan_id}) do
    with :ok <- RequestParams.require_uuid(plan_id, "plan_id"),
         {:ok, report} <-
           RequestParams.fetch_not_found(fn -> NeuZeit.Planning.Quality.report(plan_id) end) do
      json(conn, %{
        data: %{
          cohorts: report.cohorts,
          teachers: report.teachers,
          sequences: report.sequences,
          rooms: report.rooms
        },
        meta: NeuZeit.Planning.Quality.verdicts(report)
      })
    end
  end

  def create(conn, params) do
    with {:ok, plan} <- Planning.create_plan(params["plan"] || params) do
      conn
      |> put_status(:created)
      |> json(%{data: ApiJSON.data(plan)})
    end
  end

  def show(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, plan} <- RequestParams.fetch_not_found(fn -> Planning.get_plan!(id) end) do
      json(conn, %{data: ApiJSON.data(plan)})
    end
  end

  def update(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, plan} <- RequestParams.fetch_not_found(fn -> Planning.get_plan!(id) end),
         {:ok, plan} <- Planning.update_plan(plan, conn.body_params["plan"] || conn.body_params) do
      json(conn, %{data: ApiJSON.data(plan)})
    end
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, plan} <- RequestParams.fetch_not_found(fn -> Planning.get_plan!(id) end),
         {:ok, _plan} <- delete_plan(plan) do
      send_resp(conn, :no_content, "")
    end
  end

  def clone(conn, params) do
    id = plan_id(params)

    with :ok <- RequestParams.require_uuid(id),
         {:ok, plan} <-
           RequestParams.handle_not_found(fn ->
             Planning.clone_plan(id, conn.body_params["plan"] || conn.body_params)
           end) do
      conn
      |> put_status(:created)
      |> json(%{data: ApiJSON.data(plan)})
    end
  end

  def publish(conn, params) do
    id = plan_id(params)

    with :ok <- RequestParams.require_uuid(id),
         {:ok, plan} <-
           RequestParams.handle_not_found(fn ->
             Planning.publish_plan(id, allow_partial: params["allow_partial"] in [true, "true"])
           end) do
      json(conn, %{data: ApiJSON.data(plan)})
    end
  end

  def checks(conn, params) do
    id = plan_id(params)

    with :ok <- RequestParams.require_uuid(id),
         {:ok, checks} <- RequestParams.fetch_not_found(fn -> Planning.check_plan(id) end) do
      json(conn, %{data: checks})
    end
  end

  def advisories(conn, params) do
    id = plan_id(params)

    with :ok <- RequestParams.require_uuid(id),
         {:ok, advisories} <-
           RequestParams.fetch_not_found(fn -> Planning.plan_advisories(id) end) do
      json(conn, %{data: advisories})
    end
  end

  def solve(conn, params) do
    id = plan_id(params)

    with :ok <- RequestParams.require_uuid(id),
         :ok <- ensure_plan_exists(id),
         {:ok, result} <- RequestParams.handle_not_found(fn -> Planning.solve_plan(id) end) do
      json(conn, %{data: result})
    else
      {:error, :already_running} ->
        {:error, {:conflict, "Timetable generation is already running for this plan."}}

      error ->
        error
    end
  end

  defp ensure_plan_exists(id) do
    case RequestParams.fetch_not_found(fn -> Planning.get_plan!(id) end) do
      {:ok, _plan} -> :ok
      error -> error
    end
  end

  defp plan_id(%{"plan_id" => id}), do: id
  defp plan_id(%{"id" => id}), do: id

  defp delete_plan(plan) do
    Planning.delete_plan(plan)
  rescue
    Ecto.ConstraintError -> {:error, {:conflict, "Resource is referenced by other records"}}
  end
end
