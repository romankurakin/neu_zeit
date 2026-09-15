defmodule NeuZeit.Catalog.Course do
  use NeuZeit.Schema

  import Ecto.Changeset

  schema "courses" do
    field :code, :string
    field :title, :string

    has_many :components, NeuZeit.Catalog.CourseComponent
    has_many :translations, NeuZeit.Catalog.CourseTranslation

    timestamps()
  end

  def changeset(course, attrs) do
    course
    |> cast(attrs, [:code, :title])
    |> validate_required([:title])
    |> validate_length(:code, min: 1, max: 50)
    |> validate_length(:title, min: 1, max: 200)
    |> unique_constraint(:code)
  end
end
