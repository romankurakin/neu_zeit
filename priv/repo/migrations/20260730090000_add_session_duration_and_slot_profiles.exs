defmodule NeuZeit.Repo.Migrations.AddSessionDurationAndSlotProfiles do
  use Ecto.Migration

  def up do
    create table(:slot_profiles) do
      add :term_id, references(:terms, on_delete: :delete_all), null: false
      add :name, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:slot_profiles, [:term_id, :name])
    create unique_index(:slot_profiles, [:id, :term_id])

    create table(:slot_profile_cells) do
      add :slot_profile_id, references(:slot_profiles, on_delete: :delete_all), null: false
      add :day, :integer, null: false
      add :slot, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:slot_profile_cells, [:slot_profile_id, :day, :slot])
    create constraint(:slot_profile_cells, :slot_profile_cells_day_positive_ck, check: "day > 0")

    create constraint(:slot_profile_cells, :slot_profile_cells_slot_positive_ck,
             check: "slot > 0"
           )

    alter table(:sessions) do
      add :duration_slots, :integer, null: false, default: 1
      add :slot_profile_id, :uuid
    end

    create index(:sessions, [:slot_profile_id])

    create constraint(:sessions, :sessions_duration_slots_positive_ck,
             check: "duration_slots > 0"
           )

    execute """
            ALTER TABLE sessions
              ADD CONSTRAINT sessions_slot_profile_term_fkey
              FOREIGN KEY (slot_profile_id, term_id) REFERENCES slot_profiles (id, term_id)
              ON DELETE RESTRICT
            """,
            "ALTER TABLE sessions DROP CONSTRAINT sessions_slot_profile_term_fkey"

    execute "ALTER TABLE placements DROP CONSTRAINT placements_no_overlapping_week_room"

    alter table(:placements) do
      add :duration_slots, :integer, null: false, default: 1
    end

    create constraint(:placements, :placements_duration_slots_positive_ck,
             check: "duration_slots > 0"
           )

    execute """
            ALTER TABLE placements
              ADD CONSTRAINT placements_no_overlapping_week_room
              EXCLUDE USING gist (
                plan_id WITH =,
                day WITH =,
                int4range(slot, slot + duration_slots, '[)') WITH &&,
                room_id WITH =,
                week_mask gist__int_ops WITH &&
              )
            """,
            "ALTER TABLE placements DROP CONSTRAINT placements_no_overlapping_week_room"
  end

  def down do
    execute "ALTER TABLE placements DROP CONSTRAINT placements_no_overlapping_week_room"

    alter table(:placements) do
      remove :duration_slots
    end

    execute """
    ALTER TABLE placements
      ADD CONSTRAINT placements_no_overlapping_week_room
      EXCLUDE USING gist (
        plan_id WITH =,
        day WITH =,
        slot WITH =,
        room_id WITH =,
        week_mask gist__int_ops WITH &&
      )
    """

    execute "ALTER TABLE sessions DROP CONSTRAINT sessions_slot_profile_term_fkey"

    alter table(:sessions) do
      remove :slot_profile_id
      remove :duration_slots
    end

    drop table(:slot_profile_cells)
    drop table(:slot_profiles)
  end
end
