defmodule NeuZeit.Catalog.Teacher do
  use NeuZeit.Schema

  import Ecto.Changeset

  schema "teachers" do
    field :name, :string

    has_many :sessions, NeuZeit.Catalog.Session
    has_many :availability_cells, NeuZeit.Catalog.TeacherAvailabilityCell

    timestamps()
  end

  def changeset(teacher, attrs) do
    teacher
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 100)
    |> unique_constraint(:name)
  end
end
