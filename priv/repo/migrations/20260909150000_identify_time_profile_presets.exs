defmodule NeuZeit.Repo.Migrations.IdentifyTimeProfilePresets do
  use Ecto.Migration

  def change do
    alter table(:slot_profiles) do
      add :preset_key, :string
    end

    create unique_index(:slot_profiles, [:term_id, :preset_key])
  end
end
