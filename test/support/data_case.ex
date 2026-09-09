defmodule NeuZeit.DataCase do
  @moduledoc """
  Sets up database tests in a SQL sandbox.

  Database changes are rolled back after each test. Use `async: true`
  for independent PostgreSQL tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias NeuZeit.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import NeuZeit.DataCase
    end
  end

  setup tags do
    NeuZeit.DataCase.setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(NeuZeit.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    # Sandbox transactions live for an entire test. Take the production schedule
    # lock before any fixture inserts, avoiding lock-order inversion with other
    # tests inserting the same unique registry values.
    NeuZeit.Planning.SharedResources.lock!()
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
