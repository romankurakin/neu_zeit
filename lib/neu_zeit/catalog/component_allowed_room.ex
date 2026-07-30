defmodule NeuZeit.Catalog.ComponentAllowedRoom do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @foreign_key_type Ecto.UUID

  schema "component_allowed_rooms" do
    belongs_to :component, NeuZeit.Catalog.CourseComponent,
      primary_key: true,
      foreign_key: :component_id

    belongs_to :room, NeuZeit.Catalog.Room, primary_key: true
  end

  def changeset(allowed_room, attrs) do
    allowed_room
    |> cast(attrs, [:component_id, :room_id])
    |> validate_required([:component_id, :room_id])
    |> foreign_key_constraint(:component_id)
    |> foreign_key_constraint(:room_id)
    |> unique_constraint([:component_id, :room_id])
  end
end
