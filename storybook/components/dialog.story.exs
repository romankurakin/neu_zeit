defmodule NeuZeitWeb.Stories.Dialog do
  use PhoenixStorybook.Story, :example
  use Gettext, backend: NeuZeitWeb.Gettext
  import NeuZeitWeb.UI.Dialog
  import NeuZeitWeb.CoreComponents, only: [button: 1]
  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, open: false, name: "Anna Weber")}
  @impl true
  def handle_event("open", _params, socket), do: {:noreply, assign(socket, :open, true)}
  def handle_event("close", _params, socket), do: {:noreply, assign(socket, :open, false)}

  def handle_event("save", %{"name" => name}, socket),
    do: {:noreply, assign(socket, name: name, open: false)}

  @impl true
  def render(assigns) do
    ~H"""
    <.button type="button" phx-click="open">Edit teacher</.button>
    <p class="mt-2">{@name}</p>
    <.dialog :if={@open} id="teacher-dialog" title="Edit teacher" on_cancel="close">
      <form id="dialog-name-form" phx-submit="save">
        <label class="fieldset"><span class="fieldset-legend">Name</span><input
          class="input w-full"
          name="name"
          value={@name}
          required
          autofocus
        /></label>
      </form>
      <:actions>
        <.button type="button" phx-click="close">Cancel</.button>
        <.button type="submit" form="dialog-name-form" variant="primary">Save</.button>
      </:actions>
    </.dialog>
    """
  end
end
