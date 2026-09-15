defmodule NeuZeit.Repo.Migrations.SimplifyCourses do
  use Ecto.Migration

  def change do
    alter table(:courses) do
      modify :code, :string, null: true, from: {:string, null: false}
      remove :credits
    end
  end
end
