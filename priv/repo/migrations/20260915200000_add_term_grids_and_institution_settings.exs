defmodule NeuZeit.Repo.Migrations.AddTermGridsAndInstitutionSettings do
  use Ecto.Migration

  def change do
    alter table(:terms) do
      add :grid, :map
    end

    execute fn ->
              repo().query!("UPDATE terms SET grid = $1", [
                NeuZeit.Scheduling.Defaults.policy().grid
              ])
            end,
            fn -> :ok end

    alter table(:terms) do
      modify :grid, :map, null: false, from: :map
    end

    create table(:institution_settings, primary_key: false) do
      add :id, :integer, primary_key: true
      add :name, :string, null: false
      add :timezone, :string, null: false
      add :supported_locales, {:array, :string}, null: false
      add :default_locale, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create constraint(:institution_settings, :institution_settings_singleton_ck, check: "id = 1")

    create constraint(:institution_settings, :institution_settings_default_locale_ck,
             check: "default_locale = ANY(supported_locales)"
           )
  end
end
