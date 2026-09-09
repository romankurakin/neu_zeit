defmodule NeuZeitWeb.Stories.EmptyState do
  use PhoenixStorybook.Story, :example
  use Gettext, backend: NeuZeitWeb.Gettext
  import NeuZeitWeb.UI.Table, only: [table: 1]
  import NeuZeitWeb.UI.EmptyState, only: [empty_state: 1]

  @impl true
  def render(assigns) do
    ~H"""
    <.empty_state title={gettext("No sessions yet")} icon="hero-rectangle-stack" />
    <.table id="empty-table" rows={[]} empty_message={gettext("No sessions scheduled this week.")}>
      <:col label={gettext("Session")}></:col>
      <:col label={gettext("Room")}></:col>
    </.table>
    """
  end
end
