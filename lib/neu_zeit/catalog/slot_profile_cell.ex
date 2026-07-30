defmodule NeuZeit.Catalog.SlotProfileCell do
  use NeuZeit.Schema

  import Ecto.Changeset

  schema "slot_profile_cells" do
    field :day, :integer
    field :slot, :integer

    belongs_to :slot_profile, NeuZeit.Catalog.SlotProfile

    timestamps()
  end

  def changeset(cell, attrs) do
    days_count = length(NeuZeit.Config.grid!().days)
    slots_count = length(NeuZeit.Config.grid!().slots)

    cell
    |> cast(attrs, [:day, :slot])
    |> validate_required([:day, :slot])
    |> validate_number(:day, greater_than: 0, less_than_or_equal_to: days_count)
    |> validate_number(:slot, greater_than: 0, less_than_or_equal_to: slots_count)
    |> unique_constraint([:slot_profile_id, :day, :slot])
  end
end
