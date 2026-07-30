defmodule NeuZeit.Schema do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema

      @primary_key {:id, Ecto.UUID, autogenerate: [version: 7]}
      @foreign_key_type Ecto.UUID
      @timestamps_opts [type: :utc_datetime]
    end
  end
end
