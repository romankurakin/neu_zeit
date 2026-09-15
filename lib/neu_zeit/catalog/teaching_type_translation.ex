defmodule NeuZeit.Catalog.TeachingTypeTranslation do
  use NeuZeit.Schema
  import Ecto.Changeset

  schema "teaching_type_translations" do
    field :locale, :string
    field :name, :string
    belongs_to :teaching_type, NeuZeit.Catalog.TeachingType, type: :string
    timestamps()
  end

  def changeset(translation, attrs) do
    translation
    |> cast(attrs, [:locale, :name])
    |> NeuZeit.Catalog.Translation.validate(:name, 100)
    |> unique_constraint([:teaching_type_id, :locale])
    |> unique_constraint(:name, name: :teaching_type_translations_locale_name_index)
  end
end
