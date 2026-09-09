defmodule NeuZeit.Catalog.WriteSupport do
  @moduledoc false
  import Ecto.Query, warn: false
  alias Ecto.Multi
  alias NeuZeit.Repo

  def maybe_replace(multi, _name, nil, _fun), do: multi

  def maybe_replace(multi, name, _ids, fun), do: Multi.run(multi, name, fun)

  def maybe_normalize_existing_ids(nil, _field, _schema, _repo_schema), do: {:ok, nil}

  def maybe_normalize_existing_ids(ids, field, schema, repo_schema) do
    normalize_existing_ids(ids, field, schema, repo_schema)
  end

  def normalize_existing_ids(ids, field, schema, repo_schema) when is_list(ids) do
    with {:ok, ids} <- cast_ids(ids, field, schema),
         :ok <- require_ids(ids, field, schema),
         :ok <- ensure_existing_ids(ids, field, schema, repo_schema) do
      {:ok, ids}
    end
  end

  def normalize_existing_ids(_ids, field, schema, _repo_schema) do
    {:error, error_changeset(schema, field, "must be a non-empty list of ids")}
  end

  defp cast_ids(ids, field, schema) do
    ids
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
      case Ecto.UUID.cast(id) do
        {:ok, uuid} ->
          {:cont, {:ok, [uuid | acc]}}

        :error ->
          {:halt, {:error, error_changeset(schema, field, "contains invalid ids")}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, ids |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp require_ids(ids, _field, _schema) when is_list(ids) and ids != [], do: :ok

  defp require_ids(_ids, field, schema) do
    {:error, error_changeset(schema, field, "must be a non-empty list of ids")}
  end

  defp ensure_existing_ids(ids, field, schema, repo_schema) do
    existing_ids =
      repo_schema
      |> where([record], record.id in ^ids)
      |> select([record], record.id)
      |> Repo.all()
      |> MapSet.new()

    if Enum.all?(ids, &MapSet.member?(existing_ids, &1)) do
      :ok
    else
      {:error, error_changeset(schema, field, "contains unknown ids")}
    end
  end

  def error_changeset(schema, field, message) do
    schema
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(field, message)
  end

  def transaction_result(fun) do
    case Repo.transaction(fn ->
           NeuZeit.Planning.SharedResources.lock!()

           case fun.() do
             {:ok, result} -> result
             :ok -> :ok
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  def unwrap_multi({:ok, result}, key), do: {:ok, Map.fetch!(result, key)}

  def unwrap_multi({:error, _step, reason, _changes}, _key), do: {:error, reason}

  def unwrap_multi({:error, reason}, _key), do: {:error, reason}

  def preload_result({:ok, record}, associations),
    do: {:ok, Repo.preload(record, associations)}

  def preload_result({:error, reason}, _associations), do: {:error, reason}

  def attr(attrs, key, default \\ nil)

  def attr(attrs, key, default) when is_atom(key) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end
end
