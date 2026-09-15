defmodule NeuZeit.Scheduling.Grid do
  @moduledoc "A term's ordered time slots and teaching week, starting on Monday."
  use Ecto.Type
  @days ~w(Mon Tue Wed Thu Fri Sat Sun)

  def type, do: :map
  def days, do: @days

  def cast(value) when is_map(value) do
    days = Map.get(value, :days, Map.get(value, "days"))
    slots = Map.get(value, :slots, Map.get(value, "slots"))

    slots =
      if is_map(slots),
        do:
          slots
          |> Enum.sort_by(fn {key, _} -> String.to_integer(to_string(key)) end)
          |> Enum.map(&elem(&1, 1)),
        else: slots

    if is_list(days) and is_list(slots) and Enum.all?(slots, &is_map/1) do
      {:ok,
       %{
         days: days,
         slots:
           Enum.map(slots, fn slot ->
             %{start: Map.get(slot, :start, slot["start"]), end: Map.get(slot, :end, slot["end"])}
           end)
       }}
    else
      :error
    end
  rescue
    ArgumentError -> :error
  end

  def cast(_), do: :error
  def load(value), do: cast(value)
  def dump(value), do: cast(value)

  def validate(%{days: days, slots: slots}) do
    ranges = Enum.map(slots, &{minutes(&1.start), minutes(&1.end)})

    cond do
      days == [] or days != Enum.take(@days, length(days)) ->
        {:error, "Teaching days must start on Monday and follow calendar order."}

      slots == [] or length(slots) > 24 ->
        {:error, "Enter between 1 and 24 time slots."}

      Enum.any?(ranges, fn {a, b} -> is_nil(a) or is_nil(b) or a >= b end) ->
        {:error, "Enter a valid start and end time for every slot."}

      Enum.any?(Enum.chunk_every(ranges, 2, 1, :discard), fn [{_, b}, {c, _}] -> b > c end) ->
        {:error, "Time slots must be ordered and must not overlap."}

      ranges |> Enum.map(fn {a, b} -> b - a end) |> Enum.uniq() |> length() != 1 ->
        {:error, "Use the same duration for every time slot."}

      true ->
        :ok
    end
  end

  def minutes(time) when is_binary(time) do
    case Time.from_iso8601(time <> ":00") do
      {:ok, time} -> time.hour * 60 + time.minute
      _ -> nil
    end
  end

  def minutes(_), do: nil

  def span(grid, slot, duration) do
    with true <- is_integer(slot) and slot > 0 and is_integer(duration) and duration > 0,
         %{start: start} <- Enum.at(grid.slots, slot - 1),
         %{end: finish} <- Enum.at(grid.slots, slot + duration - 2) do
      {minutes(start), minutes(finish)}
    else
      _ -> nil
    end
  end
end
