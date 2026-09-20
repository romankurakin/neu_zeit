defmodule NeuZeit.Catalog.Workload do
  @moduledoc "A semester teaching requirement and the inputs used to distribute it."
  use NeuZeit.Schema
  import Ecto.Changeset

  alias NeuZeit.Catalog.{Term, WeekPattern, WorkloadDistribution}

  schema "workloads" do
    belongs_to :term, Term
    belongs_to :course_component, NeuZeit.Catalog.CourseComponent
    belongs_to :teacher, NeuZeit.Catalog.Teacher
    belongs_to :slot_profile, NeuZeit.Catalog.SlotProfile
    field :cohort_ids, {:array, Ecto.UUID}, virtual: true, default: []
    many_to_many :cohorts, NeuZeit.Catalog.Cohort, join_through: "workload_cohorts"
    has_many :sessions, NeuZeit.Catalog.Session
    field :week_mask, {:array, :integer}, default: []
    field :duration_slots, :integer, default: 1
    field :automatic_weeks, :boolean, default: false
    field :contact_hours, :decimal
    field :rounding_mode, Ecto.Enum, values: [:up, :down], default: :up
    field :remainder_parity, Ecto.Enum, values: [:odd, :even], default: :odd
    field :sequence_group, :string
    timestamps()
  end

  @session_fields ~w(course_component_id teacher_id slot_profile_id cohort_ids week_mask duration_slots sequence_group automatic_weeks)a
  @policy_fields ~w(rounding_mode remainder_parity)a

  def new(%Term{} = term),
    do: %__MODULE__{term_id: term.id, week_mask: WeekPattern.all(term.weeks_count)}

  def session_attributes(workload), do: Map.take(workload, @session_fields)

  def changeset(workload, %Term{} = term, attrs \\ %{}) do
    workload
    |> cast(attrs, (@session_fields -- [:automatic_weeks]) ++ [:contact_hours | @policy_fields])
    |> update_change(:cohort_ids, &Enum.uniq/1)
    |> validate_required([
      :contact_hours,
      :course_component_id,
      :teacher_id,
      :cohort_ids,
      :week_mask,
      :duration_slots | @policy_fields
    ])
    |> validate_number(:contact_hours, greater_than: 0)
    |> validate_length(:cohort_ids, min: 1)
    |> validate_length(:sequence_group, max: 100)
    |> validate_number(:duration_slots,
      greater_than: 0,
      less_than_or_equal_to: length(term.grid.slots)
    )
    |> validate_term(term)
    |> normalize_weeks(term)
    |> validate_capacity(term)
    |> foreign_key_constraint(:term_id)
    |> foreign_key_constraint(:course_component_id)
    |> foreign_key_constraint(:teacher_id)
    |> foreign_key_constraint(:slot_profile_id)
  end

  @doc "Builds an editable proposal even when the selected rounding exceeds capacity."
  def preview(input, term, snapshot \\ nil)

  def preview(%Ecto.Changeset{} = changeset, %Term{} = term, snapshot) do
    invalid_input? =
      Enum.any?(changeset.errors, fn {field, {_message, opts}} ->
        field in [:term_id, :contact_hours, :duration_slots, :week_mask | @policy_fields] &&
          opts[:validation] != :capacity
      end)

    if invalid_input?,
      do: nil,
      else:
        WorkloadDistribution.propose(apply_changes(changeset), term, snapshot,
          parity_changed?: Map.has_key?(changeset.changes, :remainder_parity)
        )
  end

  def preview(%__MODULE__{} = workload, %Term{} = term, snapshot),
    do: WorkloadDistribution.propose(workload, term, snapshot)

  defp validate_term(changeset, term) do
    if get_field(changeset, :term_id) == term.id,
      do: changeset,
      else: add_error(changeset, :term_id, "is invalid")
  end

  defp normalize_weeks(changeset, term) do
    case WeekPattern.validate(get_field(changeset, :week_mask), term.weeks_count) do
      {:ok, mask} -> put_change(changeset, :week_mask, mask)
      _ -> add_error(changeset, :week_mask, "must be a non-empty list of weeks within the term")
    end
  end

  defp validate_capacity(changeset, term) do
    case WorkloadDistribution.quantities(apply_changes(changeset), term) do
      %{within_capacity?: false} ->
        add_error(changeset, :contact_hours, "Teaching load exceeds the available time.",
          validation: :capacity
        )

      _ ->
        changeset
    end
  end
end
