defmodule NeuZeitWeb.Stories.Diagnostics do
  use PhoenixStorybook.Story, :example
  use Gettext, backend: NeuZeitWeb.Gettext
  import NeuZeitWeb.Scheduling.Diagnostics

  @impl true
  def render(assigns) do
    ~H"""
    <.diagnostic_list
      id="room-conflicts"
      entries={[
        %{type: "room_conflict", message: "Room 101 is occupied on Monday at 09:50.", weeks: [3, 4]}
      ]}
      empty_title="No conflicts"
    />
    """
  end
end
