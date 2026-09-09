defmodule NeuZeitWeb.Stories.SessionCard do
  use PhoenixStorybook.Story, :example
  use Gettext, backend: NeuZeitWeb.Gettext
  import NeuZeitWeb.Scheduling.SessionCard, only: [session_card: 1]
  alias NeuZeitWeb.Storybook.Fixtures

  @impl true
  def render(assigns) do
    ~H"""
    <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
      <.session_card :for={session <- Fixtures.sessions()} id={session.id} session={session} weeks_count={15} />
    </div>
    """
  end
end
