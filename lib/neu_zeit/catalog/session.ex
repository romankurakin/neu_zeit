defmodule NeuZeit.Catalog.Session do
  use NeuZeit.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias NeuZeit.Catalog.{SlotProfile, TeacherAvailabilityCell, Term, WeekPattern}

  schema "sessions" do
    field :workload_id, Ecto.UUID
    field :automatic_weeks, :boolean, default: false
    field :sequence_group, :string
    field :week_mask, {:array, :integer}
    field :duration_slots, :integer, default: 1
    field :delivery_mode, Ecto.Enum, values: [:in_person, :online], default: :in_person

    field :cohort_ids, {:array, :binary_id}, virtual: true

    belongs_to :term, Term
    belongs_to :course_component, NeuZeit.Catalog.CourseComponent
    belongs_to :teacher, NeuZeit.Catalog.Teacher
    belongs_to :slot_profile, SlotProfile

    many_to_many :cohorts, NeuZeit.Catalog.Cohort, join_through: "session_cohorts"
    has_many :placements, NeuZeit.Planning.Placement

    timestamps()
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :term_id,
      :course_component_id,
      :automatic_weeks,
      :teacher_id,
      :slot_profile_id,
      :sequence_group,
      :week_mask,
      :duration_slots,
      :delivery_mode
    ])
    |> validate_required([
      :workload_id,
      :term_id,
      :course_component_id,
      :automatic_weeks,
      :teacher_id,
      :week_mask,
      :duration_slots,
      :delivery_mode
    ])
    |> validate_length(:sequence_group, max: 100)
    |> validate_duration()
    |> normalize_week_mask()
    |> foreign_key_constraint(:term_id)
    |> foreign_key_constraint(:course_component_id)
    |> foreign_key_constraint(:teacher_id)
    |> foreign_key_constraint(:slot_profile_id, name: :sessions_slot_profile_term_fkey)
    |> check_constraint(:duration_slots, name: :sessions_duration_slots_positive_ck)
    |> check_constraint(:delivery_mode, name: :sessions_delivery_mode_ck)
    |> unique_constraint([:id, :term_id])
    |> prepare_changes(&validate_week_mask_bounds/1)
    |> prepare_changes(&validate_profile_duration/1)
    |> prepare_changes(&validate_teacher_availability/1)
  end

  def update_changeset(session, attrs) do
    session
    |> change()
    |> reject_fields(attrs, [:term_id])
    |> cast(attrs, [
      :course_component_id,
      :automatic_weeks,
      :teacher_id,
      :slot_profile_id,
      :sequence_group,
      :week_mask,
      :duration_slots,
      :delivery_mode
    ])
    |> validate_required([
      :workload_id,
      :term_id,
      :course_component_id,
      :automatic_weeks,
      :teacher_id,
      :week_mask,
      :duration_slots,
      :delivery_mode
    ])
    |> validate_length(:sequence_group, max: 100)
    |> validate_duration()
    |> normalize_week_mask()
    |> foreign_key_constraint(:course_component_id)
    |> foreign_key_constraint(:teacher_id)
    |> foreign_key_constraint(:slot_profile_id, name: :sessions_slot_profile_term_fkey)
    |> check_constraint(:duration_slots, name: :sessions_duration_slots_positive_ck)
    |> check_constraint(:delivery_mode, name: :sessions_delivery_mode_ck)
    |> prepare_changes(&validate_week_mask_bounds/1)
    |> prepare_changes(&validate_profile_duration/1)
    |> prepare_changes(&validate_teacher_availability/1)
  end

  defp validate_duration(changeset) do
    validate_number(changeset, :duration_slots,
      greater_than: 0,
      less_than_or_equal_to: length(NeuZeit.Config.grid!(get_field(changeset, :term_id)).slots)
    )
  end

  defp reject_fields(changeset, attrs, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      if Map.has_key?(attrs, field) or Map.has_key?(attrs, Atom.to_string(field)) do
        add_error(changeset, field, "is read-only")
      else
        changeset
      end
    end)
  end

  defp normalize_week_mask(changeset) do
    case get_change(changeset, :week_mask) do
      nil ->
        changeset

      mask ->
        case WeekPattern.normalize(mask) do
          {:ok, normalized} ->
            put_change(changeset, :week_mask, normalized)

          {:error, _reason} ->
            add_error(changeset, :week_mask, "must be a non-empty list of week numbers")
        end
    end
  end

  defp validate_week_mask_bounds(changeset) do
    with term_id when not is_nil(term_id) <- get_field(changeset, :term_id),
         mask when is_list(mask) <- get_field(changeset, :week_mask),
         %Term{} = term <- changeset.repo.get(Term, term_id),
         {:ok, normalized} <- WeekPattern.validate(mask, term.weeks_count) do
      put_change(changeset, :week_mask, normalized)
    else
      {:error, :out_of_bounds} ->
        add_error(changeset, :week_mask, "must be inside the term week range")

      {:error, _reason} ->
        add_error(changeset, :week_mask, "is invalid")

      nil ->
        changeset

      _ ->
        changeset
    end
  end

  defp validate_profile_duration(changeset) do
    with true <- changeset.valid?,
         profile_id when not is_nil(profile_id) <- get_field(changeset, :slot_profile_id),
         duration when is_integer(duration) <- get_field(changeset, :duration_slots) do
      slots_count = length(NeuZeit.Config.grid!(get_field(changeset, :term_id)).slots)

      valid_start? =
        changeset.repo.exists?(
          from cell in NeuZeit.Catalog.SlotProfileCell,
            where:
              cell.slot_profile_id == ^profile_id and
                cell.slot + ^duration - 1 <= ^slots_count
        )

      if valid_start? do
        changeset
      else
        add_error(
          changeset,
          :slot_profile_id,
          "has no start cell that fits the session duration"
        )
      end
    else
      _ -> changeset
    end
  end

  defp validate_teacher_availability(changeset) do
    with true <- changeset.valid?,
         term_id when not is_nil(term_id) <- get_field(changeset, :term_id),
         teacher_id when not is_nil(teacher_id) <- get_field(changeset, :teacher_id),
         duration when is_integer(duration) <- get_field(changeset, :duration_slots) do
      availability_cells =
        changeset.repo.all(
          from cell in TeacherAvailabilityCell,
            where: cell.term_id == ^term_id and cell.teacher_id == ^teacher_id
        )

      profile_cells =
        case get_field(changeset, :slot_profile_id) do
          nil ->
            nil

          profile_id ->
            changeset.repo.all(
              from cell in NeuZeit.Catalog.SlotProfileCell,
                where: cell.slot_profile_id == ^profile_id
            )
        end

      if TeacherAvailabilityCell.schedulable?(
           availability_cells,
           profile_cells,
           duration,
           NeuZeit.Config.grid!(term_id)
         ) do
        changeset
      else
        add_error(
          changeset,
          :teacher_id,
          "availability and slot profile leave no valid start for this session"
        )
      end
    else
      _ -> changeset
    end
  end
end
