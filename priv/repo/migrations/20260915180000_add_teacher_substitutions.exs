defmodule NeuZeit.Repo.Migrations.AddTeacherSubstitutions do
  use Ecto.Migration

  def up do
    alter table(:schedule_exceptions) do
      add :new_teacher_id, references(:teachers, type: :uuid, on_delete: :restrict)
    end

    create index(:schedule_exceptions, [:new_teacher_id])

    drop index(:schedule_exceptions, [:session_id, :occurrence_date],
           name: :exceptions_one_override_per_occurrence
         )

    create unique_index(:schedule_exceptions, [:session_id, :occurrence_date],
             where: "status = 'active' AND kind IN ('cancel', 'move', 'substitute')",
             name: :exceptions_one_override_per_occurrence
           )

    drop constraint(:schedule_exceptions, :exceptions_kind_ck)
    drop constraint(:schedule_exceptions, :exceptions_payload_ck)

    create constraint(:schedule_exceptions, :exceptions_kind_ck,
             check: "kind IN ('cancel', 'move', 'add', 'substitute')"
           )

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
