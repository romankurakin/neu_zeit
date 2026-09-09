defmodule NeuZeitWeb.Stories.WeekPicker do
  use PhoenixStorybook.Story, :example
  use Gettext, backend: NeuZeitWeb.Gettext
  import NeuZeitWeb.Scheduling.WeekPicker, only: [week_picker: 1]

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, :week, 3)}

  @impl true
  def handle_event("select_week", %{"week" => week}, socket) do
    {week, ""} = Integer.parse(week)
    {:noreply, assign(socket, :week, min(15, max(1, week)))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.week_picker weeks_count={15} current={@week} busiest={7} holiday={4} />
    """
  end
end
