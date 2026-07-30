defmodule NeuZeit.Catalog.SessionCohort do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @foreign_key_type Ecto.UUID

  schema "session_cohorts" do
    belongs_to :session, NeuZeit.Catalog.Session, primary_key: true
    belongs_to :cohort, NeuZeit.Catalog.Cohort, primary_key: true
  end

  def changeset(session_cohort, attrs) do
    session_cohort
    |> cast(attrs, [:session_id, :cohort_id])
    |> validate_required([:session_id, :cohort_id])
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:cohort_id)
    |> unique_constraint([:session_id, :cohort_id])
  end
end
