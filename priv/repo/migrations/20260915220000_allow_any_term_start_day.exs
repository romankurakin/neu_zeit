defmodule NeuZeit.Repo.Migrations.AllowAnyTermStartDay do
  use Ecto.Migration

  def up do
    drop constraint(:terms, :terms_starts_on_monday_ck)
  end

  def down do
    create constraint(:terms, :terms_starts_on_monday_ck,
             check: "EXTRACT(ISODOW FROM starts_on) = 1"
           )
  end
end
