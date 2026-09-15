defmodule NeuZeit.Scheduling.TermDates do
  @moduledoc "Calendar weeks anchored on Monday, with independent term boundaries."

  def week_start(%{starts_on: starts_on}),
    do: Date.add(starts_on, 1 - Date.day_of_week(starts_on))

  def date(term, week, day), do: Date.add(week_start(term), (week - 1) * 7 + day - 1)

  def week(term, date), do: Integer.floor_div(Date.diff(date, week_start(term)), 7) + 1

  def within?(term, date) do
    not Date.before?(date, term.starts_on) and
      (is_nil(term.ends_on) or not Date.after?(date, term.ends_on))
  end
end
