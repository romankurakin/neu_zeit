defmodule NeuZeitWeb.Stories.Card do
  use PhoenixStorybook.Story, :example
  use Gettext, backend: NeuZeitWeb.Gettext
  import NeuZeitWeb.UI.Card
  import NeuZeitWeb.CoreComponents, only: [button: 1]
  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, name: "Anna Weber", editing: false)}

  @impl true
  def handle_event("toggle", _params, socket), do: {:noreply, update(socket, :editing, &(!&1))}

  def handle_event("save", %{"name" => name}, socket),
    do: {:noreply, assign(socket, name: name, editing: false)}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="grid items-start gap-4 md:grid-cols-2">
      <.card title="Teacher">
        <p>Anna Weber</p>
      </.card>
      <.card title="Teacher" subtitle="Contact details">
        <:header_actions>
          <.button type="button" variant="ghost" phx-click="toggle">{if @editing,
            do: "Cancel",
            else: "Edit"}</.button>
        </:header_actions>
        <p :if={!@editing}>{@name}</p>
        <form :if={@editing} id="card-name-form" phx-submit="save">
          <label class="fieldset"><span class="fieldset-legend">Name</span><input
            name="name"
            value={@name}
            class="input w-full"
            required
          /></label>
        </form>
        <:footer :if={@editing}>
          <.button type="submit" form="card-name-form" variant="primary">Save</.button>
        </:footer>
      </.card>
    </div>
    """
  end
end
