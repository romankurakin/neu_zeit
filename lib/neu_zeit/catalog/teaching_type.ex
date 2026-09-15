defmodule NeuZeit.Catalog.TeachingType do
  use NeuZeit.Schema
  import Ecto.Changeset
  alias NeuZeit.Catalog.TeachingTypeTranslation

  # Existing component kinds remain stable references when their names change.
  @primary_key {:id, :string, autogenerate: false}
  schema "teaching_types" do
    field :names, {:map, :string}, virtual: true, default: %{}
    has_many :translations, TeachingTypeTranslation, on_replace: :delete
    has_many :components, NeuZeit.Catalog.CourseComponent, foreign_key: :kind
    timestamps()
  end

  @doc "Names are patched by locale. Omitted locales are preserved, blank values remove a translation."
  def changeset(teaching_type, attrs \\ %{}) do
    translations =
      if Ecto.assoc_loaded?(teaching_type.translations), do: teaching_type.translations, else: []

    existing = Map.new(translations, &{&1.locale, &1.name})
    changeset = cast(%{teaching_type | names: existing}, attrs, [:names])

    if changeset.valid? do
      names =
        existing
        |> Map.merge(get_field(changeset, :names) || %{})
        |> Map.new(fn {locale, name} -> {locale, if(name, do: String.trim(name), else: "")} end)
        |> Map.reject(fn {_locale, name} -> name == "" end)

      children =
        names
        |> Enum.sort()
        |> Enum.map(fn {locale, name} ->
          record = Enum.find(translations, &(&1.locale == locale)) || %TeachingTypeTranslation{}
          TeachingTypeTranslation.changeset(record, %{locale: locale, name: name})
        end)

      changeset = changeset |> put_change(:names, names) |> put_assoc(:translations, children)

      if names == %{},
        do: add_error(changeset, :names, "Enter a name in at least one language."),
        else: changeset
    else
      changeset
    end
  end
end
