defmodule NeuZeit.Catalog.WeekPattern do
  @moduledoc """
  Utilities for explicit teaching-week sets.
  """

  def all(weeks_count) when is_integer(weeks_count) and weeks_count > 0 do
    Enum.to_list(1..weeks_count)
  end

  def odd(weeks_count), do: Enum.filter(all(weeks_count), &(rem(&1, 2) == 1))
  def even(weeks_count), do: Enum.filter(all(weeks_count), &(rem(&1, 2) == 0))

  def block(first_week, last_week, weeks_count)
      when is_integer(first_week) and is_integer(last_week) and first_week <= last_week do
    first_week..last_week
    |> Enum.to_list()
    |> validate!(weeks_count)
  end

  def overlap?(left, right) when is_list(left) and is_list(right) do
    left_set = MapSet.new(left)
    Enum.any?(right, &MapSet.member?(left_set, &1))
  end

  def normalize(mask) when is_list(mask) do
    with {:ok, integers} <- coerce_integers(mask) do
      normalized = integers |> Enum.uniq() |> Enum.sort()

      if normalized == [] do
        {:error, :empty}
      else
        {:ok, normalized}
      end
    end
  end

  def normalize(_), do: {:error, :invalid}

  def validate(mask, weeks_count) do
    with {:ok, normalized} <- normalize(mask),
         :ok <- validate_bounds(normalized, weeks_count) do
      {:ok, normalized}
    end
  end

  def validate!(mask, weeks_count) do
    case validate(mask, weeks_count) do
      {:ok, normalized} -> normalized
      {:error, reason} -> raise ArgumentError, "invalid week mask: #{inspect(reason)}"
    end
  end

  defp coerce_integers(mask) do
    Enum.reduce_while(mask, {:ok, []}, fn
      value, {:ok, acc} when is_integer(value) ->
        {:cont, {:ok, [value | acc]}}

      value, {:ok, acc} when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} -> {:cont, {:ok, [int | acc]}}
          _ -> {:halt, {:error, :invalid}}
        end

      _value, _acc ->
        {:halt, {:error, :invalid}}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp validate_bounds(mask, weeks_count) when is_integer(weeks_count) and weeks_count > 0 do
    if Enum.all?(mask, &(&1 >= 1 and &1 <= weeks_count)) do
      :ok
    else
      {:error, :out_of_bounds}
    end
  end

  defp validate_bounds(_mask, _weeks_count), do: {:error, :invalid_weeks_count}
end
