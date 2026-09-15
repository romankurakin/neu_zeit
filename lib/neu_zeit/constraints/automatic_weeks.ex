defmodule NeuZeit.Constraints.AutomaticWeeks do
  alias NeuZeit.Scheduling.TermDates
  @moduledoc "Checks that generated meetings occur on teaching dates."

  def errors(term, placements, sessions \\ %{}) do
    Enum.flat_map(placements, fn placement ->
      session = Map.get(sessions, placement.session_id) || Map.get(placement, :session)

      if session && Map.get(session, :automatic_weeks, false) do
        for week <- placement.week_mask,
            date = TermDates.date(term, week, placement.day),
            Date.before?(date, term.starts_on) or Date.after?(date, term.ends_on) or
              date in (term.excluded_dates || []) do
          %{
            type: "automatic_meeting_date",
            placement_ids: [placement.id],
            session_ids: [placement.session_id],
            date: date,
            message: "A generated meeting must fall on a teaching date."
          }
        end
      else
        []
      end
    end)
  end

  def validate(term, placements) do
    case errors(term, placements) do
      [] -> :ok
      errors -> {:error, %{errors: errors}}
    end
  end
end
