defmodule NeuZeitWeb.CurriculumController do
  use NeuZeitWeb, :controller

  alias NeuZeit.Curriculum
  alias NeuZeitWeb.{ApiJSON, RequestParams}

  action_fallback NeuZeitWeb.FallbackController

  @doc """
  Contact-hour coverage for every course taught in a term.
  """
  def term_coverage(conn, %{"term_id" => term_id}) do
    with :ok <- RequestParams.require_uuid(term_id, "term_id"),
         {:ok, rows} <-
           RequestParams.fetch_not_found(fn -> NeuZeit.Curriculum.term_coverage(term_id) end) do
      json(conn, %{
        data: ApiJSON.data(rows),
        meta: %{
          basis: "session_definitions",
          scheduled_hours:
            "legacy name for planned hours; use /api/plans/:id/coverage for calendar hours"
        }
      })
    end
  end

  def plan_coverage(conn, %{"plan_id" => id}) do
    with :ok <- RequestParams.require_uuid(id, "plan_id"),
         {:ok, rows} <- RequestParams.fetch_not_found(fn -> Curriculum.plan_coverage(id) end) do
      json(conn, %{data: ApiJSON.data(rows), meta: %{basis: "planned_and_calendar", plan_id: id}})
    end
  end

  def coverage(conn, %{"term_id" => term_id, "course_id" => course_id}) do
    with :ok <- RequestParams.require_uuid(term_id, "term_id"),
         :ok <- RequestParams.require_uuid(course_id, "course_id"),
         {:ok, coverage} <-
           RequestParams.fetch_not_found(fn ->
             Curriculum.course_contact_coverage(term_id, course_id)
           end) do
      json(conn, %{data: ApiJSON.data(coverage)})
    end
  end
end
