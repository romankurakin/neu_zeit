defmodule NeuZeit.Repo.Migrations.AddDeliveryModes do
  use Ecto.Migration

  def up do
    alter table(:workloads) do
      add :delivery_mode, :string, null: false, default: "in_person"
    end

    alter table(:sessions) do
      add :delivery_mode, :string, null: false, default: "in_person"
    end

    execute "ALTER TABLE placements ALTER COLUMN room_id DROP NOT NULL"

    alter table(:schedule_exceptions) do
      add :new_delivery_mode, :string
    end

    create constraint(:workloads, :workloads_delivery_mode_ck,
             check: "delivery_mode IN ('in_person', 'online')"
           )

    create constraint(:sessions, :sessions_delivery_mode_ck,
             check: "delivery_mode IN ('in_person', 'online')"
           )

    create constraint(:schedule_exceptions, :exceptions_new_delivery_mode_ck,
             check: "new_delivery_mode IS NULL OR new_delivery_mode IN ('in_person', 'online')"
           )

    drop constraint(:schedule_exceptions, :exceptions_payload_ck)

    create constraint(:schedule_exceptions, :exceptions_payload_ck,
             check: """
             (kind = 'cancel' AND new_slot IS NULL AND new_room_id IS NULL
              AND new_teacher_id IS NULL AND new_delivery_mode IS NULL) OR
             (kind IN ('move', 'add') AND new_slot IS NOT NULL
              AND (new_delivery_mode IS NULL
                   OR (new_delivery_mode = 'online' AND new_room_id IS NULL)
                   OR (COALESCE(new_delivery_mode, 'in_person') = 'in_person' AND new_room_id IS NOT NULL))) OR
             (kind = 'substitute' AND new_teacher_id IS NOT NULL AND new_slot IS NULL
              AND new_room_id IS NULL AND new_date IS NULL AND new_delivery_mode IS NULL)
             """
           )
  end

  def down do
    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM workloads WHERE delivery_mode = 'online')
         OR EXISTS (SELECT 1 FROM sessions WHERE delivery_mode = 'online')
         OR EXISTS (SELECT 1 FROM schedule_exceptions WHERE new_delivery_mode = 'online')
         OR EXISTS (SELECT 1 FROM placements WHERE room_id IS NULL) THEN
        RAISE EXCEPTION 'convert or remove online schedule data before rolling back delivery modes';
      END IF;
    END
    $$
    """

    drop constraint(:schedule_exceptions, :exceptions_payload_ck)
    drop constraint(:schedule_exceptions, :exceptions_new_delivery_mode_ck)
    drop constraint(:sessions, :sessions_delivery_mode_ck)
    drop constraint(:workloads, :workloads_delivery_mode_ck)

    alter table(:schedule_exceptions) do
      remove :new_delivery_mode
    end

    execute "ALTER TABLE placements ALTER COLUMN room_id SET NOT NULL"

    alter table(:sessions) do
      remove :delivery_mode
    end

    alter table(:workloads) do
      remove :delivery_mode
    end

    create constraint(:schedule_exceptions, :exceptions_payload_ck,
             check: """
             (kind = 'cancel' AND new_slot IS NULL AND new_room_id IS NULL AND new_teacher_id IS NULL) OR
             (kind IN ('move', 'add') AND new_slot IS NOT NULL AND new_room_id IS NOT NULL) OR
             (kind = 'substitute' AND new_teacher_id IS NOT NULL AND new_slot IS NULL
              AND new_room_id IS NULL AND new_date IS NULL)
             """
           )
  end
end
