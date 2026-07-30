defmodule NeuZeit.Catalog.Term do
  use NeuZeit.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  schema "terms" do
    field :name, :string
    field :starts_on, :date
    field :ends_on, :date
    field :excluded_dates, {:array, :date}, default: []
    field :weeks_count, :integer

    has_many :sessions, NeuZeit.Catalog.Session
    has_many :slot_profiles, NeuZeit.Catalog.SlotProfile
    has_many :teacher_availability_cells, NeuZeit.Catalog.TeacherAvailabilityCell
    has_many :plans, NeuZeit.Planning.Plan

    timestamps()
  end

  def changeset(term, attrs) do
    term
    |> cast(attrs, [:name, :starts_on, :ends_on, :excluded_dates])
    |> validate_required([:name, :starts_on, :ends_on])
    |> validate_starts_on_week_start()
    |> validate_change(:ends_on, fn :ends_on, ends_on ->
      starts_on = get_field(term |> cast(attrs, [:starts_on]), :starts_on)

      if starts_on && Date.compare(ends_on, starts_on) == :lt do
        [ends_on: "must be on or after starts_on"]
      else
        []
      end
    end)
    |> put_weeks_count()
    |> validate_number(:weeks_count, greater_than: 0)
    |> normalize_excluded_dates()
    |> check_constraint(:ends_on, name: :terms_dates_order_ck)
    |> check_constraint(:starts_on, name: :terms_starts_on_monday_ck)
    |> check_constraint(:weeks_count, name: :terms_weeks_count_positive_ck)
    |> prepare_changes(&validate_weeks_cover_existing_masks/1)
  end

  defp validate_weeks_cover_existing_masks(changeset) do
    with term_id when not is_nil(term_id) <- changeset.data.id,
         weeks_count when is_integer(weeks_count) <- get_change(changeset, :weeks_count) do
      session_masks =
        changeset.repo.all(
          from s in NeuZeit.Catalog.Session, where: s.term_id == ^term_id, select: s.week_mask
        )

      placement_masks =
        changeset.repo.all(
          from p in NeuZeit.Planning.Placement,
            where: p.term_id == ^term_id,
            select: p.week_mask
        )

      max_used = [session_masks, placement_masks] |> List.flatten() |> Enum.max(fn -> 0 end)

      if max_used > weeks_count do
        add_error(
          changeset,
          :ends_on,
          "term must keep at least #{max_used} weeks; existing sessions or placements use week #{max_used}"
        )
      else
        changeset
      end
    else
      _ -> changeset
    end
  end

  defp validate_starts_on_week_start(changeset) do
    validate_change(changeset, :starts_on, fn :starts_on, starts_on ->
      if Date.day_of_week(starts_on) == 1 do
        []
      else
        [starts_on: "must be a Monday"]
      end
    end)
  end

  defp put_weeks_count(changeset) do
    starts_on = get_field(changeset, :starts_on)
    ends_on = get_field(changeset, :ends_on)

    if starts_on && ends_on && Date.compare(ends_on, starts_on) != :lt do
      put_change(changeset, :weeks_count, div(Date.diff(ends_on, starts_on), 7) + 1)
    else
      changeset
    end
  end

  defp normalize_excluded_dates(changeset) do
    changeset =
      case get_change(changeset, :excluded_dates) do
        nil -> changeset
        dates -> put_change(changeset, :excluded_dates, dates |> Enum.uniq() |> Enum.sort(Date))
      end

    validate_excluded_dates(changeset)
  end

  defp validate_excluded_dates(changeset) do
    dates = get_field(changeset, :excluded_dates) || []
    starts_on = get_field(changeset, :starts_on)
    ends_on = get_field(changeset, :ends_on)
    days_count = length(NeuZeit.Config.grid!().days)

    cond do
      dates == [] ->
        changeset

      starts_on && ends_on &&
          Enum.any?(dates, &(Date.before?(&1, starts_on) or Date.after?(&1, ends_on))) ->
        add_error(changeset, :excluded_dates, "must be within the term")

      Enum.any?(dates, &(Date.day_of_week(&1) > days_count)) ->
        add_error(changeset, :excluded_dates, "must fall on teaching days")

      true ->
        changeset
    end
  end
end
