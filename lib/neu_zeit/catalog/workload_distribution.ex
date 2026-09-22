defmodule NeuZeit.Catalog.WorkloadDistribution do
  @moduledoc "Pure calculation of teaching hours and proposed changes to generated sessions."

  alias NeuZeit.Catalog.{Term, WeekPattern, Workload, WorkloadSnapshot}

  defstruct [
    :meeting_count,
    :lower_count,
    :upper_count,
    :lower_hours,
    :upper_hours,
    :required_hours,
    :planned_hours,
    :difference,
    :minutes_per_meeting,
    :hours_per_meeting,
    :capacity,
    :within_capacity?,
    :lower_fits?,
    :upper_fits?,
    :series_count,
    :automatic_weeks,
    :parity_choice?,
    retained: [],
    removed: [],
    new_masks: [],
    masks: []
  ]

  @doc "Proposes session changes independently of input order. Does not write data."
  def propose(workload, %Term{} = term, snapshot \\ nil, opts \\ []) do
    validate_context!(workload, term, snapshot)

    case quantities(workload, term) do
      nil ->
        nil

      result ->
        sessions = ordered_sessions(snapshot)
        parity_changed? = Keyword.get(opts, :parity_changed?, false)

        # Keep alternatives available when the selected count exceeds capacity.
        # Do not build session lists that cannot fit in the semester.
        {retained, removed, new_masks} =
          if result.within_capacity?,
            do: reconcile(sessions, workload, result.meeting_count, parity_changed?),
            else: {[], [], []}

        masks = Enum.map(retained, fn {_session, mask} -> mask end) ++ new_masks
        remainder = rem(result.meeting_count, length(workload.week_mask))
        odd = Enum.count(workload.week_mask, &(rem(&1, 2) == 1))
        even = length(workload.week_mask) - odd

        struct!(
          __MODULE__,
          Map.merge(result, %{
            retained: retained,
            removed: removed,
            new_masks: new_masks,
            masks: masks,
            series_count: length(masks),
            automatic_weeks: workload.automatic_weeks,
            parity_choice?:
              not workload.automatic_weeks && remainder > 0 &&
                remainder == odd && remainder == even
          })
        )
    end
  end

  @doc "Computes both whole-meeting alternatives in the semester's academic-hour unit."
  def quantities(workload, %Term{} = term) do
    hours = workload.contact_hours
    duration = workload.duration_slots
    unit = term.academic_hour_minutes

    with true <- workload.term_id == term.id,
         true <- match?(%Decimal{coef: coef} when is_integer(coef), hours),
         true <- Decimal.compare(hours, 0) == :gt,
         true <- is_integer(duration) && duration > 0 && duration <= length(term.grid.slots),
         true <- is_integer(unit) && unit > 0,
         true <- workload.rounding_mode in [:up, :down],
         true <- workload.remainder_parity in [:odd, :even],
         {:ok, weeks} <- WeekPattern.validate(workload.week_mask, term.weeks_count),
         true <- weeks == workload.week_mask do
      minutes = duration * slot_minutes(term.grid)
      required_minutes = Decimal.mult(hours, unit)
      floor = required_minutes |> Decimal.div_int(minutes) |> Decimal.to_integer()
      exact? = Decimal.equal?(Decimal.rem(required_minutes, minutes), 0)
      lower = max(1, floor)
      upper = max(1, if(exact?, do: floor, else: floor + 1))
      meetings = if workload.rounding_mode == :down, do: lower, else: upper
      planned = academic_hours(meetings * minutes, term)
      capacity = length(weeks) * length(term.grid.days) * div(length(term.grid.slots), duration)

      %{
        meeting_count: meetings,
        lower_count: lower,
        upper_count: upper,
        lower_hours: academic_hours(lower * minutes, term),
        upper_hours: academic_hours(upper * minutes, term),
        required_hours: hours,
        planned_hours: planned,
        difference: Decimal.sub(planned, hours),
        minutes_per_meeting: minutes,
        hours_per_meeting: academic_hours(minutes, term),
        capacity: capacity,
        within_capacity?: meetings <= capacity,
        lower_fits?: lower <= capacity,
        upper_fits?: upper <= capacity
      }
    else
      _ -> nil
    end
  end

  def duration_options(%Term{} = term) do
    minutes = slot_minutes(term.grid)

    for slots <- 1..length(term.grid.slots),
        do: %{
          slots: slots,
          minutes: slots * minutes,
          hours: academic_hours(slots * minutes, term)
        }
  end

  def meeting_count(sessions), do: Enum.reduce(sessions, 0, &(repeats(&1) + &2))

  def planned_hours(sessions, %Term{} = term) do
    academic_hours(planned_minutes(sessions, term), term)
  end

  def planned_minutes(sessions, %Term{} = term) do
    Enum.reduce(sessions, 0, fn session, sum ->
      sum + repeats(session) * session.duration_slots * slot_minutes(term.grid)
    end)
  end

  def synchronized?(workload, %Term{} = term, sessions) do
    case quantities(workload, term) do
      %{within_capacity?: true, meeting_count: meetings} ->
        counts_match? =
          if workload.automatic_weeks,
            do:
              length(sessions) == meetings &&
                Enum.all?(sessions, &(&1.week_mask == workload.week_mask)),
            else: reusable_masks?(sessions, workload, meetings)

        attributes = Workload.session_attributes(workload) |> Map.delete(:week_mask)

        counts_match? &&
          Enum.all?(sessions, fn session ->
            actual =
              session
              |> Map.take(Map.keys(attributes))
              |> Map.put(:cohort_ids, Enum.map(session.cohorts, & &1.id) |> Enum.sort())

            actual == Map.update!(attributes, :cohort_ids, &Enum.sort/1)
          end)

      _ ->
        false
    end
  end

  defp repeats(%{automatic_weeks: true}), do: 1
  defp repeats(session), do: length(session.week_mask)

  defp academic_hours(minutes, term),
    do: Decimal.div(Decimal.new(minutes), Decimal.new(term.academic_hour_minutes))

  defp slot_minutes(grid) do
    slot = hd(grid.slots)
    NeuZeit.Scheduling.Grid.minutes(slot.end) - NeuZeit.Scheduling.Grid.minutes(slot.start)
  end

  defp ordered_sessions(nil), do: []

  defp ordered_sessions(%WorkloadSnapshot{} = snapshot) do
    protected = MapSet.union(snapshot.placed_ids, snapshot.history_ids)
    Enum.sort_by(snapshot.sessions, &{not MapSet.member?(protected, &1.id), &1.id})
  end

  defp validate_context!(workload, term, snapshot) do
    valid_snapshot? =
      case snapshot do
        nil ->
          is_nil(workload.id)

        %WorkloadSnapshot{} ->
          snapshot.id == workload.id && snapshot.requirement.id == workload.id &&
            snapshot.requirement.term_id == term.id &&
            Enum.all?(
              snapshot.sessions,
              &(&1.workload_id == workload.id && &1.term_id == term.id)
            ) &&
            MapSet.subset?(
              MapSet.union(snapshot.placed_ids, snapshot.history_ids),
              MapSet.new(snapshot.sessions, & &1.id)
            )

        _ ->
          false
      end

    unless workload.term_id == term.id && valid_snapshot? do
      raise ArgumentError,
            "Distribution requires the workload's term and its matching editing snapshot; only new workloads can omit the snapshot"
    end
  end

  defp generated_masks(workload, meetings) do
    weeks = workload.week_mask
    full = List.duplicate(weeks, div(meetings, length(weeks)))
    remainder = rem(meetings, length(weeks))

    if remainder == 0 do
      full
    else
      odd = Enum.filter(weeks, &(rem(&1, 2) == 1))
      even = weeks -- odd
      candidates = if workload.remainder_parity == :even, do: [even, odd], else: [odd, even]

      mask =
        Enum.find(candidates, &(length(&1) == remainder)) ||
          for i <- 0..(remainder - 1),
              do: Enum.at(weeks, div((2 * i + 1) * length(weeks), 2 * remainder))

      full ++ [mask]
    end
  end

  defp reusable_masks?(sessions, workload, meetings) do
    not workload.automatic_weeks &&
      Enum.sum(Enum.map(sessions, &length(&1.week_mask))) == meetings &&
      Enum.all?(sessions, &valid_mask?(&1.week_mask, workload.week_mask))
  end

  defp valid_mask?(mask, allowed),
    do:
      is_list(mask) && mask != [] && mask == Enum.sort(Enum.uniq(mask)) &&
        Enum.all?(mask, &(&1 in allowed))

  defp reconcile(sessions, %{automatic_weeks: true} = workload, meetings, _parity_changed?) do
    {retained, removed} = Enum.split(sessions, meetings)

    {Enum.map(retained, &{&1, workload.week_mask}), removed,
     List.duplicate(workload.week_mask, meetings - length(retained))}
  end

  defp reconcile(sessions, workload, meetings, parity_changed?) do
    if not parity_changed? && reusable_masks?(sessions, workload, meetings) do
      {Enum.map(sessions, &{&1, &1.week_mask}), [], []}
    else
      # Match compatible series first so a new full series cannot consume a
      # manually selected remainder. Input order already prioritizes protections.
      {kept, remaining, unmatched} =
        Enum.reduce(generated_masks(workload, meetings), {[], sessions, []}, fn mask,
                                                                                {kept, remaining,
                                                                                 created} ->
          match =
            Enum.find(remaining, &(&1.week_mask == mask)) ||
              if(mask != workload.week_mask && not parity_changed?,
                do:
                  Enum.find(
                    remaining,
                    &(length(&1.week_mask) == length(mask) &&
                        valid_mask?(&1.week_mask, workload.week_mask))
                  )
              )

          if match,
            do: {kept ++ [{match, match.week_mask}], List.delete(remaining, match), created},
            else: {kept, remaining, created ++ [mask]}
        end)

      {updated, removed} = Enum.split(remaining, length(unmatched))
      {kept ++ Enum.zip(updated, unmatched), removed, Enum.drop(unmatched, length(updated))}
    end
  end
end
