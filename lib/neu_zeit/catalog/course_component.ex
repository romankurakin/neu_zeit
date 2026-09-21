defmodule NeuZeit.Catalog.CourseComponent do
  use NeuZeit.Schema

  import Ecto.Changeset

  schema "course_components" do
    field :kind, :string

    belongs_to :teaching_type, NeuZeit.Catalog.TeachingType,
      foreign_key: :kind,
      type: :string,
      define_field: false

    belongs_to :course, NeuZeit.Catalog.Course

    many_to_many :allowed_rooms, NeuZeit.Catalog.Room,
      join_through: "component_allowed_rooms",
      join_keys: [component_id: :id, room_id: :id]

    has_many :sessions, NeuZeit.Catalog.Session

    timestamps()
  end

  def changeset(component, attrs) do
    component
    |> cast(attrs, [:course_id, :kind])
    |> validate_required([:course_id, :kind])
    |> foreign_key_constraint(:kind, name: :course_components_kind_fkey)
    |> foreign_key_constraint(:course_id)
    |> unique_constraint([:course_id, :kind])
  end

  def room_options(%{allowed_rooms: []}, rooms), do: rooms
  def room_options(%{allowed_rooms: rooms}, _rooms), do: rooms

  def room_allowed?(%{allowed_rooms: []}, room_id), do: not is_nil(room_id)

  def room_allowed?(%{allowed_rooms: rooms}, room_id),
    do: Enum.any?(rooms, &(&1.id == room_id))
end
