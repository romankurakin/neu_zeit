defmodule NeuZeitWeb.SlotProfileController do
  use NeuZeitWeb, :controller

  alias NeuZeit.Catalog
  alias NeuZeitWeb.{ApiJSON, RequestParams}

  action_fallback NeuZeitWeb.FallbackController

  def index(conn, params) do
    term_id = params["term_id"]

    with :ok <- maybe_require_uuid(term_id) do
      json(conn, %{data: ApiJSON.data(Catalog.list_slot_profiles(term_id))})
    end
  end

  def create(conn, params) do
    with {:ok, profile} <- Catalog.create_slot_profile(params["slot_profile"] || params) do
      conn
      |> put_status(:created)
      |> json(%{data: ApiJSON.data(profile)})
    end
  end

  def create_defaults(conn, %{"term_id" => term_id}) do
    with :ok <- RequestParams.require_uuid(term_id),
         {:ok, term} <- RequestParams.fetch_not_found(fn -> Catalog.get_term!(term_id) end),
         {:ok, profiles} <- Catalog.ensure_default_slot_profiles(term) do
      conn
      |> put_status(:created)
      |> json(%{data: ApiJSON.data(profiles)})
    end
  end

  def show(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, profile} <- RequestParams.fetch_not_found(fn -> Catalog.get_slot_profile!(id) end) do
      json(conn, %{data: ApiJSON.data(profile)})
    end
  end

  def update(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, profile} <- RequestParams.fetch_not_found(fn -> Catalog.get_slot_profile!(id) end),
         {:ok, profile} <-
           Catalog.update_slot_profile(
             profile,
             conn.body_params["slot_profile"] || conn.body_params
           ) do
      json(conn, %{data: ApiJSON.data(profile)})
    end
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- RequestParams.require_uuid(id),
         {:ok, profile} <- RequestParams.fetch_not_found(fn -> Catalog.get_slot_profile!(id) end),
         {:ok, _profile} <- delete_profile(profile) do
      send_resp(conn, :no_content, "")
    end
  end

  defp maybe_require_uuid(nil), do: :ok
  defp maybe_require_uuid(id), do: RequestParams.require_uuid(id)

  defp delete_profile(profile) do
    Catalog.delete_slot_profile(profile)
  rescue
    Ecto.ConstraintError -> {:error, {:conflict, "Slot profile is assigned to sessions"}}
  end
end
