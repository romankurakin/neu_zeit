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
    |> validate_number(:credits, greater_than: 0)
    |> unique_constraint(:code)
  end
end
