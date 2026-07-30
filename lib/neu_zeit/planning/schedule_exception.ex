defmodule NeuZeit.Planning.ScheduleException do
  use NeuZeit.Schema

  import Ecto.Changeset

  @kinds ~w(cancel move add)
  @statuses ~w(active reverted)

  schema "schedule_exceptions" do
    field :kind, :string
    field :occurrence_date, :date
    field :new_date, :date
    field :new_slot, :integer
    field :reason, :string
    field :status, :string, default: "active"
    field :created_by, :string

    belongs_to :term, NeuZeit.Catalog.Term
    belongs_to :session, NeuZeit.Catalog.Session
    belongs_to :new_room, NeuZeit.Catalog.Room

    timestamps(updated_at: false)
  end

  def kinds, do: @kinds
  def statuses, do: @statuses

  def changeset(exception, attrs) do
    exception
    |> cast(attrs, [
      :term_id,
      :session_id,
      :kind,
      :occurrence_date,
      :new_date,
      :new_slot,
      :new_room_id,
      :reason,
      :status,
      :created_by
    ])
    |> validate_required([:term_id, :session_id, :kind, :occurrence_date, :reason, :status])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:new_slot, greater_than: 0)
    |> validate_payload()
    |> prepare_changes(&validate_grid_and_term_dates/1)
    |> foreign_key_constraint(:session_id, name: :exceptions_session_term_fkey)
    |> foreign_key_constraint(:new_room_id)
    |> unique_constraint([:session_id, :occurrence_date],
      name: :exceptions_one_override_per_occurrence
    )
    |> check_constraint(:kind, name: :exceptions_payload_ck)
  end

  def update_changeset(exception, attrs) do
    exception
    |> changeset(attrs)
    |> reject_fields(attrs, [:term_id, :session_id])
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

  defp validate_payload(changeset) do
    kind = get_field(changeset, :kind)
    new_slot = get_field(changeset, :new_slot)
    new_room_id = get_field(changeset, :new_room_id)

    cond do
      kind == "cancel" && (new_slot || new_room_id) ->
        changeset
        |> add_error(:new_slot, "must be blank for cancellations")
        |> add_error(:new_room_id, "must be blank for cancellations")

      kind in ["move", "add"] && (is_nil(new_slot) || is_nil(new_room_id)) ->
        changeset
        |> validate_required([:new_slot, :new_room_id])

      true ->
        changeset
    end
  end

  defp validate_grid_and_term_dates(changeset) do
    grid = NeuZeit.Config.grid!()

    changeset
    |> validate_slot_bound(length(grid.slots), session_duration(changeset))
    |> validate_term_dates(length(grid.days))
  end

  defp validate_slot_bound(changeset, slots_per_day, duration_slots) do
    case get_field(changeset, :new_slot) do
      slot when is_integer(slot) and slot + duration_slots - 1 > slots_per_day ->
        add_error(
          changeset,
          :new_slot,
          "is outside the configured slot grid (1..#{slots_per_day})"
        )

      _ ->
        changeset
    end
  end

  defp session_duration(changeset) do
    with session_id when not is_nil(session_id) <- get_field(changeset, :session_id),
         %{duration_slots: duration} <-
           changeset.repo.get(NeuZeit.Catalog.Session, session_id) do
      duration
    else
      _ -> 1
    end
  end

  defp validate_term_dates(changeset, days_count) do
    with term_id when not is_nil(term_id) <- get_field(changeset, :term_id),
         %NeuZeit.Catalog.Term{} = term <- changeset.repo.get(NeuZeit.Catalog.Term, term_id) do
      changeset
      |> validate_date_in_term(:occurrence_date, term, days_count)
      |> validate_date_in_term(:new_date, term, days_count)
    else
      _ -> changeset
    end
  end

  defp validate_date_in_term(changeset, field, term, days_count) do
    case get_field(changeset, field) do
      %Date{} = date ->
        cond do
          Date.before?(date, term.starts_on) or Date.after?(date, term.ends_on) ->
            add_error(changeset, field, "must be within the term")

          Date.day_of_week(date) > days_count ->
            add_error(changeset, field, "must be on a teaching day")

          true ->
            changeset
        end

      _ ->
        changeset
    end
  end
end
