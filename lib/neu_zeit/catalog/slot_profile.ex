defmodule NeuZeit.Catalog.SlotProfile do
  use NeuZeit.Schema

  import Ecto.Changeset

  schema "slot_profiles" do
    field :name, :string
    field :preset_key, :string

    belongs_to :term, NeuZeit.Catalog.Term

    has_many :cells, NeuZeit.Catalog.SlotProfileCell,
      on_replace: :delete,
      preload_order: [asc: :day, asc: :slot]

    has_many :sessions, NeuZeit.Catalog.Session

    timestamps()
  end

  # Recognize the old generated name and localized examples without matching arbitrary names.
  def daytime_name?(name),
    do: name in ["DAYTIME_ANY", "Weekdays, daytime", "Будни, дневное время", "Werktags, tagsüber"]

  def changeset(profile, attrs) do
    changeset = cast(profile, attrs, [:term_id, :name])
    grid = NeuZeit.Config.grid!(get_field(changeset, :term_id))

    changeset
    |> validate_required([:term_id, :name])
    |> validate_length(:name, min: 1, max: 100)
    |> cast_assoc(:cells,
      required: true,
      with: &NeuZeit.Catalog.SlotProfileCell.changeset(&1, &2, grid),
      sort_param: :cells_sort,
      drop_param: :cells_drop
    )
    |> validate_cells_present()
    |> foreign_key_constraint(:term_id)
    |> unique_constraint([:term_id, :name])
  end

  def update_changeset(profile, attrs) do
    profile
    |> changeset(attrs)
    |> reject_term_change(attrs)
  end

  defp validate_cells_present(changeset) do
    cells = get_field(changeset, :cells, [])

    if cells == [] do
      add_error(changeset, :cells, "must contain at least one allowed start")
    else
      changeset
    end
  end

  defp reject_term_change(changeset, attrs) do
    if Map.has_key?(attrs, :term_id) or Map.has_key?(attrs, "term_id") do
      add_error(changeset, :term_id, "is read-only")
    else
      changeset
    end
  end
end
