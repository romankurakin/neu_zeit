defmodule NeuZeitWeb.CurriculumController do
  use NeuZeitWeb, :controller

  alias NeuZeit.Curriculum
  alias NeuZeitWeb.{ApiJSON, RequestParams}

  action_fallback NeuZeitWeb.FallbackController

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
