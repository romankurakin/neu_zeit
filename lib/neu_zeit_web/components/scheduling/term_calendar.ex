defmodule NeuZeitWeb.Scheduling.TermCalendar do
  @moduledoc "Teaching dates and non-teaching days."
  use NeuZeitWeb, :ui_component
  alias NeuZeit.Config
  import NeuZeitWeb.Scheduling.Labels
  import NeuZeitWeb.UI.Dates

  @doc """
  Renders one row per teaching week, with dated cells for marking non-teaching days.
  """
  attr :term, :map, required: true
  attr :event, :string, default: "toggle_excluded_date"
  attr :readonly, :boolean, default: false
  attr :grid, :map, default: nil

  def term_calendar(assigns) do
    grid = assigns.grid || Config.grid!(assigns.term)
    excluded = MapSet.new(assigns.term.excluded_dates || [])

    assigns =
      assigns
      |> assign(:days, Enum.with_index(Enum.map(grid.days, &day_label/1), 1))
      |> assign(:excluded, excluded)

    ~H"""
    <div class="overflow-x-auto">
      <table class="table w-auto">
        <thead>
          <tr>
            <th class="text-right font-normal text-base-content">{gettext("Week")}</th>
            <th :for={{day, _index} <- @days} class="text-center">{day}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={week <- 1..@term.weeks_count//1}>
            <td class="text-right tabular-nums text-base-content">{week}</td>
            <td :for={{_day, day_index} <- @days} class="p-0.5 text-center">
              <% date = date_at(@term, week, day_index) %>
              <button
                type="button"
                disabled={@readonly || Date.after?(date, @term.ends_on)}
                phx-click={!@readonly && !Date.after?(date, @term.ends_on) && @event}
                phx-value-date={Date.to_iso8601(date)}
                aria-pressed={to_string(MapSet.member?(@excluded, date))}
                title={excluded_title(@excluded, date)}
                class={[
                  "w-full rounded-field px-1.5 py-1 tabular-nums type-detail motion-safe:transition-colors",
                  if(MapSet.member?(@excluded, date),
                    do: "bg-error/15 text-error line-through",
                    else: "text-base-content hover:bg-base-200"
                  ),
                  !@readonly && !Date.after?(date, @term.ends_on) && "cursor-pointer"
                ]}
              >
                <.date value={date} format="day_month" />
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp date_at(term, week, day_index),
    do: Date.add(term.starts_on, (week - 1) * 7 + (day_index - 1))

  defp excluded_title(excluded, date) do
    if MapSet.member?(excluded, date) do
      gettext("%{date} is a non-teaching day. Click to make it a teaching day.", date: date)
    else
      gettext("%{date}. Click to mark it non-teaching.", date: date)
    end
  end
end
