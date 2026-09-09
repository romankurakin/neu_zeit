defmodule NeuZeit.Repo.Migrations.AddWorkloadCohorts do
  use Ecto.Migration

  def up do
    create table(:workload_cohorts, primary_key: false) do
      add :workload_id, references(:workloads, type: :uuid, on_delete: :delete_all),
        primary_key: true

      add :cohort_id, references(:cohorts, type: :uuid), primary_key: true
    end

    execute "INSERT INTO workload_cohorts SELECT id, unnest(cohort_ids) FROM workloads ON CONFLICT DO NOTHING"

    alter table(:workloads), do: remove(:cohort_ids)
  end

  def down do
    alter table(:workloads), do: add(:cohort_ids, {:array, :uuid}, null: false, default: [])

    execute "UPDATE workloads w SET cohort_ids = (SELECT array_agg(cohort_id) FROM workload_cohorts WHERE workload_id = w.id)"

    drop table(:workload_cohorts)
  end
end
