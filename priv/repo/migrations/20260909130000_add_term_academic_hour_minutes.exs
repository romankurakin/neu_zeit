defmodule NeuZeit.Repo.Migrations.AddTermAcademicHourMinutes do
  use Ecto.Migration

  def change do
    alter table(:terms) do
      add :academic_hour_minutes, :integer, null: false, default: 45
    end

    create constraint(:terms, :terms_academic_hour_minutes_ck,
             check: "academic_hour_minutes > 0 AND academic_hour_minutes <= 60"
           )
  end
end
