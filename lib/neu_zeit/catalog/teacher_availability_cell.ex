defmodule NeuZeit.Catalog.TeacherAvailabilityCell do
  use NeuZeit.Schema

  import Ecto.Changeset

  schema "teacher_availability_cells" do
    field :day, :integer
    field :slot, :integer

    belongs_to :term, NeuZeit.Catalog.Term
    belongs_to :teacher, NeuZeit.Catalog.Teacher

    timestamps()
  end

  def changeset(cell, attrs) do
    grid = NeuZeit.Config.grid!()

    cell
    |> cast(attrs, [:term_id, :teacher_id, :day, :slot])
    |> validate_required([:term_id, :teacher_id, :day, :slot])
    |> validate_inclusion(:day, 1..length(grid.days))
    |> validate_inclusion(:slot, 1..length(grid.slots))
    |> foreign_key_constraint(:term_id)
    |> foreign_key_constraint(:teacher_id)
    |> unique_constraint([:term_id, :teacher_id, :day, :slot])
    |> check_constraint(:day, name: :teacher_availability_cells_day_positive_ck)
    |> check_constraint(:slot, name: :teacher_availability_cells_slot_positive_ck)
  end

  @doc """
  Returns the occupied slots outside a recurring availability allow-list.

  An empty list deliberately means unrestricted availability.
  """
  def unavailable_slots([], _day, _start_slot, _duration_slots), do: []

  def unavailable_slots(cells, day, start_slot, duration_slots) when is_list(cells) do
    allowed = MapSet.new(cells, &{field(&1, :day), field(&1, :slot)})

    start_slot..(start_slot + duration_slots - 1)
    |> Enum.reject(&MapSet.member?(allowed, {day, &1}))
  end

  @doc """
  Checks that a slot profile and recurring availability leave at least one valid
  start for a session of the given duration.
  """
  def schedulable?(
        availability_cells,
        profile_cells,
        duration_slots,
        grid \\ NeuZeit.Config.grid!()
      )
      when is_list(availability_cells) and is_integer(duration_slots) do
    days_count = length(grid.days)
    slots_count = length(grid.slots)

    starts =
      case profile_cells do
        nil -> for day <- 1..days_count, slot <- 1..slots_count, do: %{day: day, slot: slot}
        cells when is_list(cells) -> cells
      end

    Enum.any?(starts, fn start ->
      day = field(start, :day)
      slot = field(start, :slot)

      is_integer(day) and is_integer(slot) and day in 1..days_count and slot > 0 and
        slot + duration_slots - 1 <= slots_count and
        unavailable_slots(availability_cells, day, slot, duration_slots) == []
    end)
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
