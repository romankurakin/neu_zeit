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

  @default_limit 50
  @max_limit 100
  # Bounds the offset well below PostgreSQL's bigint limit.
  @max_offset 1_000_000
  @max_search_length 100

  @doc """
  Reads `limit` (1 to 100, default 50) and `offset` (0 to 1,000,000, default 0).
  """
  def page(params) do
    with {:ok, limit} <- integer_param(params, "limit", @default_limit, 1, @max_limit),
         {:ok, offset} <- integer_param(params, "offset", 0, 0, @max_offset) do
      {:ok, %{limit: limit, offset: offset}}
    end
  end

  @doc """
  Reads the search text `q`. Blank or missing text means no search.
  """
  def search(params) do
    case Map.get(params, "q") do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        case String.trim(value) do
          "" ->
            {:ok, nil}

          text ->
            if String.length(text) <= @max_search_length,
              do: {:ok, text},
              else: {:error, {:bad_request, "q must be at most #{@max_search_length} characters"}}
        end

      _value ->
        {:error, {:bad_request, "q must be text"}}
    end
  end

  defp integer_param(params, field, default, min, max) do
    case Map.fetch(params, field) do
      :error ->
        {:ok, default}

      {:ok, value} ->
        case is_binary(value) && Integer.parse(value) do
          {number, ""} when number >= min and number <= max ->
            {:ok, number}

          _invalid ->
            {:error, {:bad_request, "#{field} must be an integer from #{min} to #{max}"}}
        end
    end
  end
end
