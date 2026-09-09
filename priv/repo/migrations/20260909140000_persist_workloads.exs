defmodule NeuZeit.Repo.Migrations.PersistWorkloads do
  use Ecto.Migration

  def change do
    create table(:workloads, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :term_id, references(:terms, type: :uuid, on_delete: :delete_all), null: false
      add :course_component_id, references(:course_components, type: :uuid), null: false
      add :teacher_id, references(:teachers, type: :uuid), null: false
      add :slot_profile_id, references(:slot_profiles, type: :uuid)
      add :cohort_ids, {:array, :uuid}, null: false
      add :week_mask, {:array, :integer}, null: false
      add :duration_slots, :integer, null: false
      add :automatic_weeks, :boolean, null: false
      add :contact_hours, :decimal, null: false
      add :sequence_group, :text
      timestamps(type: :utc_datetime)
    end

    create constraint(:workloads, :workloads_hours_positive, check: "contact_hours > 0")
    create index(:workloads, [:term_id])
    create unique_index(:workloads, [:id, :term_id])

    alter table(:sessions) do
      add :workload_id, references(:workloads, type: :uuid, with: [term_id: :term_id])
    end

    create index(:sessions, [:workload_id])
  end
end
