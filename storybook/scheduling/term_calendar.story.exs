defmodule NeuZeitWeb.Stories.TermCalendar do
  use PhoenixStorybook.Story, :example
  use Gettext, backend: NeuZeitWeb.Gettext
  import NeuZeitWeb.Scheduling.TermCalendar
  @impl true
  def mount(_params, _session, socket),
    do:
      {:ok,
       assign(socket, :term, %{
         starts_on: ~D[2026-09-07],
         ends_on: ~D[2026-10-04],
         grid: NeuZeit.Config.grid!(),
         weeks_count: 4,
         excluded_dates: [~D[2026-09-09]]
       })}

  @impl true
  def handle_event("toggle_excluded_date", %{"date" => value}, socket) do
    date = Date.from_iso8601!(value)
    term = socket.assigns.term

    dates =
      if date in term.excluded_dates,
        do: List.delete(term.excluded_dates, date),
        else: [date | term.excluded_dates]

    {:noreply, assign(socket, :term, %{term | excluded_dates: dates})}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.term_calendar term={@term} />
    """
  end
end
