defmodule NeuZeit.Repo.Migrations.DeferPlacementRoomOverlap do
  use Ecto.Migration

  # A repair can exchange the rooms of two placements in one transaction. Such a
  # write defers this check to the commit; other writes still check each row.
  def up do
    execute "ALTER TABLE placements DROP CONSTRAINT placements_no_overlapping_week_room"
    execute constraint("DEFERRABLE INITIALLY IMMEDIATE")
  end

  def down do
    execute "ALTER TABLE placements DROP CONSTRAINT placements_no_overlapping_week_room"
    execute constraint("")
  end

  defp constraint(mode) do
    """
    ALTER TABLE placements
      ADD CONSTRAINT placements_no_overlapping_week_room
      EXCLUDE USING gist (
        plan_id WITH =,
        day WITH =,
        int4range(slot, slot + duration_slots, '[)') WITH &&,
        room_id WITH =,
        week_mask gist__int_ops WITH &&
      )
      #{mode}
    """
  end
end
