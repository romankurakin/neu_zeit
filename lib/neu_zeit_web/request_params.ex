defmodule NeuZeitWeb.RequestParams do
  @moduledoc false

  def require_uuid(value, field \\ "id") do
    case Ecto.UUID.cast(value) do
      {:ok, _uuid} -> :ok
      :error -> {:error, {:bad_request, "#{field} must be a valid UUID"}}
    end
  end

  def handle_not_found(fun) when is_function(fun, 0) do
    fun.()
  rescue
    Ecto.NoResultsError -> {:error, {:not_found, "Resource not found"}}
  end

  def fetch_not_found(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  rescue
    Ecto.NoResultsError -> {:error, {:not_found, "Resource not found"}}
  end
end
