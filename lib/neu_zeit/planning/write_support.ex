defmodule NeuZeit.Planning.WriteSupport do
  @moduledoc false
  import Ecto.Query, warn: false
  alias NeuZeit.Catalog.Term
  alias NeuZeit.Planning.Placement
  alias NeuZeit.Planning.Plan
  alias NeuZeit.Repo

  def require_id(nil, schema, field), do: error_result(schema, field, "can't be blank")

  def require_id(value, schema, field) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> error_result(schema, field, "is invalid")
    end
  end

  def ensure_draft_plan(plan_id) do
    case fetch_plan(plan_id) do
      %Plan{} = plan -> ensure_draft_plan_status(plan)
      nil -> error_result(%Placement{}, :plan_id, "does not exist")
    end
  end

  def lock_draft_plan(plan_id) do
    case fetch_plan(plan_id, lock: true) do
      %Plan{status: "draft"} = plan -> {:ok, plan}
      %Plan{} -> error_result(%Placement{}, :plan_id, "is read-only unless it is a draft")
      nil -> error_result(%Placement{}, :plan_id, "does not exist")
    end
  end

  def ensure_draft_plan_status(%Plan{status: "draft"}), do: :ok

  def ensure_draft_plan_status(%Plan{}) do
    error_result(%Placement{}, :plan_id, "is read-only unless it is a draft")
  end

  def fetch_plan(plan_id, opts \\ []) do
    query = from p in Plan, where: p.id == ^plan_id

    query =
      if Keyword.get(opts, :lock, false), do: from(p in query, lock: "FOR UPDATE"), else: query

    Repo.one(query)
  end

  def lock_plan_term(plan_id, missing \\ :changeset) do
    case Repo.one(from plan in Plan, where: plan.id == ^plan_id, select: plan.term_id) do
      nil ->
        case missing do
          :not_found -> {:error, :not_found}
          :changeset -> error_result(%Placement{}, :plan_id, "does not exist")
        end

      term_id ->
        {:ok, Repo.one!(from term in Term, where: term.id == ^term_id, lock: "FOR UPDATE")}
    end
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

  def error_result(schema, field, message) do
    {:error,
     schema
     |> Ecto.Changeset.change()
     |> Ecto.Changeset.add_error(field, message)}
  end

  def attr(attrs, key, default \\ nil)

  def attr(attrs, key, default) when is_atom(key) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  def stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end
end
