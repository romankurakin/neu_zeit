defmodule NeuZeit.Catalog.CourseTranslation do
  use NeuZeit.Schema

  import Ecto.Changeset

  schema "course_translations" do
    field :locale, :string
    field :title, :string

    belongs_to :course, NeuZeit.Catalog.Course

    timestamps()
  end

  def changeset(translation, attrs) do
    translation
    |> cast(attrs, [:course_id, :locale, :title])
    |> validate_required([:course_id, :locale, :title])
    |> validate_length(:locale, min: 2, max: 10)
    |> validate_length(:title, min: 1, max: 200)
    |> foreign_key_constraint(:course_id)
    |> unique_constraint([:course_id, :locale])
  end
end
