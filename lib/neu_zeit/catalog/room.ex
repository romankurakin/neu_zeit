defmodule NeuZeit.Catalog.Room do
  use NeuZeit.Schema

  import Ecto.Changeset

  schema "rooms" do
    field :name, :string

    belongs_to :building, NeuZeit.Catalog.Building

    many_to_many :course_components, NeuZeit.Catalog.CourseComponent,
      join_through: "component_allowed_rooms"

    timestamps()
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [:building_id, :name])
    |> validate_required([:building_id, :name])
    |> validate_length(:name, min: 1, max: 100)
    |> foreign_key_constraint(:building_id)
    |> unique_constraint([:building_id, :name])
  end
end
