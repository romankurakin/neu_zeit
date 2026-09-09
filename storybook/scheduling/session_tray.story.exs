defmodule NeuZeitWeb.Stories.SessionTray do
  use PhoenixStorybook.Story, :example
  use Gettext, backend: NeuZeitWeb.Gettext
  import NeuZeitWeb.Scheduling.SessionTray
  alias NeuZeitWeb.Storybook.Fixtures

  @impl true
  def render(assigns) do
    ~H"""
    <div class="grid items-start gap-4 md:grid-cols-2">
      <.session_tray id="unplaced-sessions" sessions={Fixtures.sessions()} weeks_count={15} />
      <.session_tray id="empty-tray" sessions={[]} weeks_count={15} />
    </div>
    """
  end
end
