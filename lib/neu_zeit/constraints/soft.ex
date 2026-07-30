defmodule NeuZeit.Constraints.Soft do
  @moduledoc """
  Phoenix-owned description of the timetable soft objective.

  Phoenix serializes the normalized groups, pairs, and weights the solver needs
  to optimize (building clustering, cohort gaps, sequence adjacency, and minimal
  perturbation). Scoring itself is owned by the solver: it optimizes this
  objective internally. Phoenix neither evaluates nor persists a score — drafts
  are compared by inspecting their placements, not by a number. This module only
  describes the objective for the solver.
  """

  alias NeuZeit.Catalog.WeekPattern
  alias NeuZeit.Config

  def weights(policy \\ Config.load!()) do
    %{
      building: get_in(policy, [:soft, :cluster_buildings, :weight]) || 0,
      gaps: get_in(policy, [:soft, :minimize_gaps, :weight]) || 0,
      active_days: get_in(policy, [:soft, :minimize_active_days, :weight]) || 0,
      sequence: get_in(policy, [:soft, :sequence_adjacency, :weight]) || 0,
      perturbation: get_in(policy, [:soft, :minimal_perturbation, :weight]) || 0,
      excluded_days: get_in(policy, [:soft, :avoid_excluded_days, :weight]) || 0
    }
  end

  def solver_rules(session_specs, policy \\ Config.load!()) do
    cohort_groups = cohort_groups(session_specs)
    compact_groups = cohort_groups ++ teacher_groups(session_specs)

    %{
      weights: weights(policy),
      building_groups: compact_groups,
      gap_groups: compact_groups,
      active_day_groups: compact_groups,
      sequence_pairs: sequence_pairs(session_specs)
    }
  end

  defp cohort_groups(session_specs) do
    session_specs
    |> Enum.flat_map(fn session ->
      for cohort_id <- session.cohorts,
          week <- session.weeks,
          do: {{cohort_id, week}, session.id}
    end)
    |> Enum.group_by(fn {key, _session_id} -> key end, fn {_key, session_id} -> session_id end)
    |> Enum.sort_by(fn {{cohort_id, week}, _session_ids} -> {cohort_id, week} end)
    |> Enum.map(fn {{_cohort_id, week}, session_ids} ->
      %{week: week, session_ids: Enum.sort(session_ids)}
    end)
    |> Enum.filter(&(length(&1.session_ids) > 1))
  end

  defp teacher_groups(session_specs) do
    session_specs
    |> Enum.flat_map(fn session ->
      case Map.get(session, :teacher) do
        nil -> []
        teacher_id -> Enum.map(session.weeks, &{{teacher_id, &1}, session.id})
      end
    end)
    |> Enum.group_by(fn {key, _session_id} -> key end, fn {_key, session_id} -> session_id end)
    |> Enum.sort_by(fn {{teacher_id, week}, _session_ids} -> {teacher_id, week} end)
    |> Enum.map(fn {{_teacher_id, week}, session_ids} ->
      %{week: week, session_ids: Enum.sort(session_ids)}
    end)
    |> Enum.filter(&(length(&1.session_ids) > 1))
  end

  defp sequence_pairs(session_specs) do
    session_specs
    |> Enum.reject(&is_nil(&1.sequence_group))
    |> Enum.group_by(& &1.sequence_group)
    |> Map.values()
    |> Enum.flat_map(&pairs/1)
    |> Enum.filter(fn {left, right} -> WeekPattern.overlap?(left.weeks, right.weeks) end)
    |> Enum.map(fn {left, right} -> %{left: left.id, right: right.id} end)
  end

  defp pairs([]), do: []
  defp pairs([_one]), do: []
  defp pairs([head | tail]), do: Enum.map(tail, &{head, &1}) ++ pairs(tail)
end
