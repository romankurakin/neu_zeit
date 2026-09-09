defmodule NeuZeit.Config do
  @moduledoc """
  Scheduling business policy used by timetable checks and solver specs.
  """

  alias NeuZeit.Scheduling.Defaults

  def load! do
    Defaults.policy()
    |> validate!()
  end

  def grid!, do: load!().grid

  def validate!(config) do
    days = config.grid[:days] || []
    slots = config.grid[:slots] || []
    supported = config.institution[:supported_locales] || []
    default = config.institution[:default_locale]
    weights = solver_weights(config)

    cond do
      default not in supported ->
        raise ArgumentError, "institution.default_locale must be in supported_locales"

      days == [] ->
        raise ArgumentError, "grid.days must not be empty"

      slots == [] ->
        raise ArgumentError, "grid.slots must not be empty"

      not valid_slot_grid?(slots) ->
        raise ArgumentError, "grid.slots must be valid, ordered, and non-overlapping"

      config.ects[:hours_per_credit] not in 25..30 ->
        raise ArgumentError, "ects.hours_per_credit must be 25..30"

      config.ects[:contact_ratio] <= 0 or config.ects[:contact_ratio] > 1 ->
        raise ArgumentError, "ects.contact_ratio must be in (0, 1]"

      config.ects[:academic_hour_minutes] <= 0 ->
        raise ArgumentError, "ects.academic_hour_minutes must be positive"

      not Enum.all?(weights, &non_negative_integer?/1) ->
        raise ArgumentError, "soft weights must be non-negative integers"

      config.solver[:time_limit] <= 0 ->
        raise ArgumentError, "solver.time_limit must be positive"

      config.solver[:workers] <= 0 ->
        raise ArgumentError, "solver.workers must be positive"

      not is_boolean(config.solver[:require_complete_solution]) ->
        raise ArgumentError, "solver.require_complete_solution must be boolean"

      true ->
        config
    end
  end

  defp solver_weights(config) do
    [
      get_in(config, [:soft, :balance_weeks, :weight]) || 0,
      get_in(config, [:soft, :cluster_buildings, :weight]),
      get_in(config, [:soft, :minimize_gaps, :weight]),
      get_in(config, [:soft, :minimize_active_days, :weight]),
      get_in(config, [:soft, :sequence_adjacency, :weight]),
      get_in(config, [:soft, :minimal_perturbation, :weight]),
      get_in(config, [:soft, :avoid_excluded_days, :weight])
    ]
  end

  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp valid_slot_grid?(slots) do
    with {:ok, ranges} <- parse_slot_ranges(slots) do
      Enum.all?(ranges, fn {start_minutes, end_minutes} -> start_minutes < end_minutes end) and
        ranges
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.all?(fn [{_start, previous_end}, {next_start, _end}] ->
          previous_end <= next_start
        end)
    else
      :error -> false
    end
  end

  defp parse_slot_ranges(slots) do
    Enum.reduce_while(slots, {:ok, []}, fn slot, {:ok, ranges} ->
      with {:ok, start_minutes} <- parse_time(slot[:start]),
           {:ok, end_minutes} <- parse_time(slot[:end]) do
        {:cont, {:ok, [{start_minutes, end_minutes} | ranges]}}
      else
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, ranges} -> {:ok, Enum.reverse(ranges)}
      :error -> :error
    end
  end

  defp parse_time(value) when is_binary(value) do
    case String.split(value, ":") do
      [hours, minutes] ->
        with {hour, ""} when hour in 0..23 <- Integer.parse(hours),
             {minute, ""} when minute in 0..59 <- Integer.parse(minutes) do
          {:ok, hour * 60 + minute}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_time(_value), do: :error
end
