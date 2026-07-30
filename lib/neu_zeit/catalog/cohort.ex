defmodule NeuZeit.Catalog.Cohort do
  use NeuZeit.Schema

  import Ecto.Changeset

  schema "cohorts" do
    field :name, :string

    many_to_many :sessions, NeuZeit.Catalog.Session, join_through: "session_cohorts"

    timestamps()
  end

  def changeset(cohort, attrs) do
    cohort
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
