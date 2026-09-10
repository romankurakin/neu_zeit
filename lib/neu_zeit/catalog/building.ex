defmodule NeuZeit.Catalog.Building do
  use NeuZeit.Schema

  import Ecto.Changeset

  schema "buildings" do
    field :name, :string

    has_many :rooms, NeuZeit.Catalog.Room

    timestamps()
  end

  def changeset(building, attrs) do
    building
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 100)
    |> unique_constraint(:name)
  end
end
