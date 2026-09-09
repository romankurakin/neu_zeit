defmodule NeuZeit.Repo.Migrations.AddAutomaticSessionWeeks do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :automatic_weeks, :boolean, null: false, default: false
    end
  end
end
