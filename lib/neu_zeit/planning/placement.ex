defmodule NeuZeit.Planning.Placement do
  use NeuZeit.Schema

  import Ecto.Changeset

  alias NeuZeit.Catalog.WeekPattern

  schema "placements" do
    field :week_mask, {:array, :integer}
    field :day, :integer
    field :slot, :integer
    field :duration_slots, :integer, default: 1
    field :locked, :boolean, default: false

    belongs_to :plan, NeuZeit.Planning.Plan
    belongs_to :session, NeuZeit.Catalog.Session
    belongs_to :term, NeuZeit.Catalog.Term
    belongs_to :room, NeuZeit.Catalog.Room

    timestamps()
  end

  def changeset(placement, attrs) do
    placement
    |> cast(attrs, [
      :plan_id,
      :session_id,
      :term_id,
      :week_mask,
      :room_id,
      :day,
      :slot,
      :duration_slots,
      :locked
    ])
    |> validate_required([
      :plan_id,
      :session_id,
      :term_id,
      :week_mask,
      :room_id,
      :day,
      :slot,
      :duration_slots
    ])
    |> validate_number(:day, greater_than: 0)
    |> validate_number(:slot, greater_than: 0)
    |> validate_number(:duration_slots, greater_than: 0)
    |> normalize_week_mask()
    |> foreign_key_constraint(:room_id)
    |> foreign_key_constraint(:plan_id, name: :placements_plan_term_fkey)
    |> foreign_key_constraint(:session_id, name: :placements_session_term_fkey)
    |> unique_constraint([:plan_id, :session_id])
    |> check_constraint(:duration_slots, name: :placements_duration_slots_positive_ck)
    |> exclusion_constraint(:week_mask, name: :placements_no_overlapping_week_room)
  end

  defp normalize_week_mask(changeset) do
    case get_change(changeset, :week_mask) do
      nil ->
        changeset

      mask ->
        case WeekPattern.normalize(mask) do
          {:ok, normalized} ->
            put_change(changeset, :week_mask, normalized)

          {:error, _reason} ->
            add_error(changeset, :week_mask, "must be a non-empty list of week numbers")
        end
    end
  end
end
