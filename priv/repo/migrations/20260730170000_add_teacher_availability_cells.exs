defmodule NeuZeit.Repo.Migrations.AddTeacherAvailabilityCells do
  use Ecto.Migration

  def change do
    create table(:teacher_availability_cells) do
      add :term_id, references(:terms, on_delete: :delete_all), null: false
      add :teacher_id, references(:teachers, on_delete: :delete_all), null: false
      add :day, :integer, null: false
      add :slot, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:teacher_availability_cells, [:term_id, :teacher_id, :day, :slot])
    create index(:teacher_availability_cells, [:teacher_id, :term_id])

    create constraint(
             :teacher_availability_cells,
             :teacher_availability_cells_day_positive_ck,
             check: "day > 0"
           )

    create constraint(
             :teacher_availability_cells,
             :teacher_availability_cells_slot_positive_ck,
             check: "slot > 0"
           )
  end
end
