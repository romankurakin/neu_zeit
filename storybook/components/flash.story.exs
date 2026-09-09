defmodule NeuZeitWeb.Stories.Flash do
  use PhoenixStorybook.Story, :example
  use Gettext, backend: NeuZeitWeb.Gettext
  import NeuZeitWeb.CoreComponents, only: [flash: 1]

  @impl true
  def handle_event("placement_error", _params, socket) do
    {:noreply,
     NeuZeitWeb.UI.Errors.put(
       socket,
       {:conflict, gettext("Room occupied in weeks %{weeks}.", weeks: "3-8")}
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.flash id="placement-error" kind={:error} flash={@flash} />
    <button class="btn" phx-click="placement_error">{gettext("Show an error")}</button>
    """
  end
end
