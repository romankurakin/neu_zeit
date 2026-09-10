defmodule NeuZeit.Catalog.Course do
  use NeuZeit.Schema

  import Ecto.Changeset

  schema "courses" do
    field :code, :string
    field :title, :string
    field :credits, :decimal

    has_many :components, NeuZeit.Catalog.CourseComponent

    timestamps()
  end

  def changeset(course, attrs) do
    course
    |> cast(attrs, [:code, :title, :credits])
    |> validate_required([:code, :title, :credits])
    |> validate_length(:code, min: 1, max: 50)
    |> validate_length(:title, min: 1, max: 200)
    |> validate_number(:credits, greater_than: 0)
    |> unique_constraint(:code)
  end
end
