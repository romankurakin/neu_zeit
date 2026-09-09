defmodule NeuZeitWeb.Stories.AlertDialog do
  use PhoenixStorybook.Story, :example
  use Gettext, backend: NeuZeitWeb.Gettext
  import NeuZeitWeb.CoreComponents, only: [flash: 1]
  import NeuZeitWeb.UI.Dialog, only: [alert_dialog: 1]

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, :confirming?, false)}

  @impl true
  def handle_event("confirm_open", _params, socket),
    do: {:noreply, assign(socket, :confirming?, true)}

  def handle_event("confirm_cancel", _params, socket),
    do: {:noreply, assign(socket, :confirming?, false)}

  def handle_event("confirm_accept", _params, socket) do
    {:noreply,
     socket
     |> assign(:confirming?, false)
     |> put_flash(:info, gettext("Publication confirmed."))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.flash id="publication-result" kind={:info} flash={@flash} />
    <button class="btn btn-primary" phx-click="confirm_open">{gettext("Publish plan")}</button>
    <.alert_dialog variant="primary" :if={@confirming?} title={gettext("Publish this plan?")}
      message={gettext("This plan will replace the published timetable. Existing one-off changes will be kept.")}
      confirm_label={gettext("Publish plan")} on_confirm="confirm_accept" on_cancel="confirm_cancel" />
    """
  end
end
