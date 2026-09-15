defmodule NeuZeit.Settings.Institution do
  use NeuZeit.Schema
  import Ecto.Changeset
  @primary_key {:id, :integer, autogenerate: false, default: 1}
  schema "institution_settings" do
    field :name, :string
    field :timezone, :string
    field :supported_locales, {:array, :string}, default: []
    field :default_locale, :string
    timestamps()
  end

  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [:name, :timezone, :supported_locales, :default_locale])
    |> update_change(:name, fn value -> if value, do: String.trim(value), else: nil end)
    |> validate_length(:name, min: 1, max: 100)
    |> validate_change(:timezone, fn :timezone, zone ->
      if zone in NeuZeit.Settings.timezones(),
        do: [],
        else: [timezone: "Choose a valid time zone."]
    end)
    |> update_change(
      :supported_locales,
      &((&1 || []) |> Enum.reject(fn value -> value == "" end) |> Enum.uniq() |> Enum.sort())
    )
    |> validate_required([:name, :timezone, :supported_locales, :default_locale])
    |> validate_subset(:supported_locales, Gettext.known_locales(NeuZeitWeb.Gettext))
    |> validate_inclusion(
      :default_locale,
      get_field(cast(settings, attrs, [:supported_locales]), :supported_locales) || []
    )
    |> check_constraint(:default_locale, name: :institution_settings_default_locale_ck)
  end
end
