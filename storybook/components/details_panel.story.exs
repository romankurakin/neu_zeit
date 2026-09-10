defmodule NeuZeitWeb.Stories.DetailsPanel do
  use PhoenixStorybook.Story, :example
  use Gettext, backend: NeuZeitWeb.Gettext
  import NeuZeitWeb.Scheduling.TeachingWeeks, only: [teaching_weeks: 1]
  import NeuZeitWeb.UI.DetailsPanel, only: [details_panel: 1]

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, :open, true)}
  @impl true
  def handle_event("close", _params, socket), do: {:noreply, assign(socket, :open, false)}
  def handle_event("open", _params, socket), do: {:noreply, assign(socket, :open, true)}

  @impl true
  def render(assigns) do
    ~H"""
    <button :if={!@open} type="button" class="btn" phx-click="open">{gettext("Open")}</button>
    <.details_panel :if={@open} title="Programmierung I" subtitle={gettext("Lab")} on_close="close">
      <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-2 type-detail">
        <dt>{gettext("Teacher")}</dt><dd>Anna Weber</dd>
        <dt>{gettext("Weeks")}</dt><dd>
          <.teaching_weeks weeks={[1, 2, 3, 4, 5, 6, 7]} total={15} />
        </dd>
      </dl>
    </.details_panel>
    """
  end
end
