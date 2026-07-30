defmodule NeuZeit.Constraints.Advisory do
  @moduledoc """
  Non-blocking timetable diagnostics for relationships that the current data
  model cannot prove.

  Legacy DKU language cohorts (D*, E*, KZ*, BS*) are schedulable cohorts in
  their own right. When one overlaps a base cohort, this module reports the pair
  for administrator review instead of guessing a parent/child relationship and
  turning it into a hard conflict.
  """

  alias NeuZeit.Catalog.WeekPattern

  @subgroup_pattern ~r/^(?:D|E|KZ|BS)[\s_-]*\d+$/iu

  def check_placements(placements) do
    placements
    |> pairs()
    |> Enum.filter(fn {left, right} -> potential_overlap?(left, right) end)
    |> Enum.map(&advisory/1)
    |> Enum.sort_by(&{&1.day, &1.slots, &1.session_ids})
  end

  defp potential_overlap?(left, right) do
    overlapping_cells?(left, right) and
      WeekPattern.overlap?(left.week_mask, right.week_mask) and
      explicit_cohorts_disjoint?(left, right) and
      base_subgroup_pair?(left.session.cohorts, right.session.cohorts)
  end

  defp overlapping_cells?(left, right) do
    left.day == right.day and left.slot < right.slot + duration(right) and
      right.slot < left.slot + duration(left)
  end

  defp explicit_cohorts_disjoint?(left, right) do
    left_ids = MapSet.new(left.session.cohorts, & &1.id)
    right_ids = MapSet.new(right.session.cohorts, & &1.id)
    MapSet.disjoint?(left_ids, right_ids)
  end

  defp base_subgroup_pair?(left_cohorts, right_cohorts) do
    (has_base?(left_cohorts) and has_subgroup?(right_cohorts)) or
      (has_subgroup?(left_cohorts) and has_base?(right_cohorts))
  end

  defp has_subgroup?(cohorts), do: Enum.any?(cohorts, &Regex.match?(@subgroup_pattern, &1.name))
  defp has_base?(cohorts), do: Enum.any?(cohorts, &(not Regex.match?(@subgroup_pattern, &1.name)))

  defp advisory({left, right}) do
    first_slot = max(left.slot, right.slot)
    last_slot = min(left.slot + duration(left) - 1, right.slot + duration(right) - 1)

    %{
      type: "unverified_cohort_overlap",
      message: "base cohort and legacy subgroup overlap; verify actual student membership",
      placement_ids: [left.id, right.id],
      session_ids: [left.session_id, right.session_id],
      day: left.day,
      slots: Enum.to_list(first_slot..last_slot),
      weeks:
        Enum.sort(MapSet.intersection(MapSet.new(left.week_mask), MapSet.new(right.week_mask))),
      cohorts: [cohort_names(left), cohort_names(right)]
    }
  end

  defp cohort_names(placement), do: Enum.map(placement.session.cohorts, & &1.name) |> Enum.sort()
  defp duration(%{duration_slots: duration}) when is_integer(duration), do: duration
  defp duration(_placement), do: 1

  defp pairs([]), do: []
  defp pairs([_one]), do: []
  defp pairs([head | tail]), do: Enum.map(tail, &{head, &1}) ++ pairs(tail)
end
