defmodule NeuZeit.Catalog.Translation do
  @moduledoc "Validation and language fallback for translated catalog text."
  import Ecto.Changeset

  def validate(changeset, field, max_length) do
    changeset
    |> update_change(field, fn value -> if value, do: String.trim(value), else: nil end)
    |> validate_required([:locale, field])
    |> validate_length(:locale, min: 2, max: 10)
    |> validate_format(:locale, ~r/^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,6})?$/)
    |> validate_length(field, min: 1, max: max_length)
  end

  def text(
        translations,
        locale,
        field,
        fallback \\ nil,
        default_locale \\ NeuZeit.Config.load!().institution.default_locale
      ) do
    names = Map.new(translations, &{&1.locale, Map.fetch!(&1, field)})

    names[locale] || fallback || names[default_locale] ||
      names |> Enum.sort() |> List.first({nil, nil}) |> elem(1)
  end
end
