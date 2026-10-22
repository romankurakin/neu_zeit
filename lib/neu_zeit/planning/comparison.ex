defmodule NeuZeit.Planning.Comparison do
  @moduledoc """
  Compares the placements and quality of two plans of one term.

  Plans of a term share sessions, so a session is matched by its id. A session
  placed in both plans with other weeks, day, time or room counts as moved.
  Locking alone does not change where a session runs, so it is not a move.
  """

  alias NeuZeit.Config
  alias NeuZeit.Planning
  alias NeuZeit.Planning.Quality

  @metrics [:gaps, :isolated_days, :long_days, :building_transitions]
  @kinds [:moved, :placed, :unplaced]

  @doc """
  Compares `before_id` with `after_id`. Both plans must belong to the same term.

  Changes are `:moved`, `:placed` (only the second plan places the session) and
  `:unplaced` (only the first plan places it). Sessions unplaced in both plans
  are not changes.
  """
  def compare(before_id, after_id) do
    before = Planning.board_data(before_id)
    after_ = Planning.board_data(after_id)

    if before.plan.term_id != after_.plan.term_id do
      raise ArgumentError, "plans must belong to the same term"
    end

    grid = Config.grid!(before.plan.term)
    before_quality = Quality.report(before_id, grid: grid)
    after_quality = Quality.report(after_id, grid: grid)

    %{
      before: before.plan,
      after: after_.plan,
      changes: changes(before.placements, after_.placements),
      totals: totals(before, after_, before_quality, after_quality),
      quality: %{
        teacher: subject_deltas(before_quality.teachers, after_quality.teachers),
        cohort: subject_deltas(before_quality.cohorts, after_quality.cohorts)
      }
    }
  end

  @doc "Counts changes by kind."
  def counts(%{changes: changes}) do
    Map.merge(Map.new(@kinds, &{&1, 0}), Enum.frequencies_by(changes, & &1.kind))
  end

  @doc """
  Groups changes by teacher or by group, with that subject's quality changes.

  A session with several groups appears under each of them. Sessions without
  a group are collected under a `nil` id after the named groups.
  """
  def group(%{changes: changes, quality: quality}, by) when by in [:teacher, :cohort] do
    changes
    |> Enum.flat_map(fn change -> Enum.map(subjects(change.session, by), &{&1, change}) end)
    |> Enum.group_by(fn {subject, _change} -> subject end, fn {_subject, change} -> change end)
    |> Enum.map(fn {{id, name}, rows} ->
      %{
        id: id,
        name: name,
        changes: Enum.sort_by(rows, &row_order/1),
        quality: Map.get(quality[by], id, [])
      }
    end)
    |> Enum.sort_by(&{is_nil(&1.id), &1.name})
  end

  defp subjects(session, :teacher), do: [{session.teacher_id, session.teacher.name}]
  defp subjects(%{cohorts: []}, :cohort), do: [{nil, nil}]
  defp subjects(session, :cohort), do: Enum.map(session.cohorts, &{&1.id, &1.name})

  defp row_order(change) do
    placement = change.after || change.before
    {Enum.find_index(@kinds, &(&1 == change.kind)), placement.day, placement.slot}
  end

  # Placements

  defp changes(before_placements, after_placements) do
    before_by_session = Map.new(before_placements, &{&1.session_id, &1})
    after_by_session = Map.new(after_placements, &{&1.session_id, &1})

    before_by_session
    |> Map.keys()
    |> Enum.concat(Map.keys(after_by_session))
    |> Enum.uniq()
    |> Enum.flat_map(&change(before_by_session[&1], after_by_session[&1]))
  end

  defp change(nil, placement),
    do: [%{kind: :placed, session: placement.session, before: nil, after: placement, fields: []}]

  defp change(placement, nil),
    do: [
      %{kind: :unplaced, session: placement.session, before: placement, after: nil, fields: []}
    ]

  defp change(before, after_) do
    case changed_fields(before, after_) do
      [] ->
        []

      fields ->
        [%{kind: :moved, session: after_.session, before: before, after: after_, fields: fields}]
    end
  end

  defp changed_fields(before, after_) do
    [
      day: before.day != after_.day,
      time: {before.slot, before.duration_slots} != {after_.slot, after_.duration_slots},
      room: before.room_id != after_.room_id,
      weeks: Enum.sort(before.week_mask) != Enum.sort(after_.week_mask)
    ]
    |> Enum.filter(fn {_field, changed} -> changed end)
    |> Enum.map(fn {field, _changed} -> field end)
  end

  # Quality

  # Quality totals add up groups and teachers, as the quality summary of a plan does.
  defp totals(before, after_, before_quality, after_quality) do
    before_verdicts = Quality.verdicts(before_quality)
    after_verdicts = Quality.verdicts(after_quality)

    [
      {:unplaced, length(before.unplaced), length(after_.unplaced)},
      {:checks, length(before.checks), length(after_.checks)},
      {:warnings, length(before.advisories), length(after_.advisories)}
      | Enum.map(@metrics, &{&1, before_verdicts[&1], after_verdicts[&1]})
    ]
    |> Enum.map(fn {key, before, after_} ->
      %{key: key, before: before, after: after_, delta: after_ - before}
    end)
  end

  # A subject without placements in one plan has no report row there, so it counts as zero.
  defp subject_deltas(before_rows, after_rows) do
    before_by_id = Map.new(before_rows, &{&1.id, &1})
    after_by_id = Map.new(after_rows, &{&1.id, &1})

    before_by_id
    |> Map.keys()
    |> Enum.concat(Map.keys(after_by_id))
    |> Enum.uniq()
    |> Map.new(fn id ->
      deltas =
        @metrics
        |> Enum.map(fn metric ->
          before = metric_value(before_by_id[id], metric)
          after_ = metric_value(after_by_id[id], metric)
          %{key: metric, before: before, after: after_, delta: after_ - before}
        end)
        |> Enum.reject(&(&1.delta == 0))

      {id, deltas}
    end)
  end

  defp metric_value(nil, _metric), do: 0
  defp metric_value(row, metric), do: Map.fetch!(row, metric)
end
