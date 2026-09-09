defmodule NeuZeit.Catalog.WorkloadCohort do
  use Ecto.Schema
  @primary_key false
  @foreign_key_type Ecto.UUID

  schema "workload_cohorts" do
    belongs_to :workload, NeuZeit.Catalog.Workload, primary_key: true
    belongs_to :cohort, NeuZeit.Catalog.Cohort, primary_key: true
  end
end
