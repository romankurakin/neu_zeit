defmodule NeuZeitWeb.Stories.WeekSelector do
  use PhoenixStorybook.Story, :example
  use Gettext, backend: NeuZeitWeb.Gettext
  import NeuZeitWeb.Scheduling.TeachingWeeks
  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, :weeks, [1, 2, 3])}
  @impl true
  def handle_event("week_mask_changed", %{"week" => value}, socket) do
    week = String.to_integer(value)

    weeks =
      if week in socket.assigns.weeks,
        do: List.delete(socket.assigns.weeks, week),
        else: Enum.sort([week | socket.assigns.weeks])

    {:noreply, assign(socket, :weeks, weeks)}
  end

  def handle_event("week_mask_changed", %{"preset" => preset}, socket) do
    weeks =
      case preset do
        "all" -> Enum.to_list(1..15)
        "odd" -> Enum.to_list(1..15//2)
        "even" -> Enum.to_list(2..15//2)
      end

    {:noreply, assign(socket, :weeks, weeks)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.week_selector id="teaching-week-selector" weeks={@weeks} total={15} />
    <div class="mt-4"><.teaching_weeks weeks={@weeks} total={15} /></div>
    """
  end
end
