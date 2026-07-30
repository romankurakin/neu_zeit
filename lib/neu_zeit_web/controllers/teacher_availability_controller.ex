defmodule NeuZeitWeb.TeacherAvailabilityController do
  use NeuZeitWeb, :controller

  alias NeuZeit.Catalog
  alias NeuZeitWeb.{ApiJSON, RequestParams}

  action_fallback NeuZeitWeb.FallbackController

  def show(conn, %{"term_id" => term_id, "teacher_id" => teacher_id}) do
    with :ok <- require_ids(term_id, teacher_id),
         {:ok, _term} <- RequestParams.fetch_not_found(fn -> Catalog.get_term!(term_id) end),
         {:ok, _teacher} <-
           RequestParams.fetch_not_found(fn -> Catalog.get_teacher!(teacher_id) end) do
      json(conn, %{data: ApiJSON.data(Catalog.list_teacher_availability(term_id, teacher_id))})
    end
  end

  def replace(conn, %{"term_id" => term_id, "teacher_id" => teacher_id}) do
    with {:ok, cells} <- fetch_cells(conn.body_params),
         :ok <- require_ids(term_id, teacher_id),
         {:ok, _term} <- RequestParams.fetch_not_found(fn -> Catalog.get_term!(term_id) end),
         {:ok, _teacher} <-
           RequestParams.fetch_not_found(fn -> Catalog.get_teacher!(teacher_id) end),
         {:ok, availability} <-
           Catalog.replace_teacher_availability(term_id, teacher_id, cells) do
      json(conn, %{data: ApiJSON.data(availability)})
    end
  end

  defp fetch_cells(%{"cells" => cells}) when is_list(cells), do: {:ok, cells}

  defp fetch_cells(_params),
    do: {:error, {:bad_request, "cells must be present and must be a list"}}

  defp require_ids(term_id, teacher_id) do
    with :ok <- RequestParams.require_uuid(term_id, "term_id"),
         :ok <- RequestParams.require_uuid(teacher_id, "teacher_id") do
      :ok
    end
  end
end
