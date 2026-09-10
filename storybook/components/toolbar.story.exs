defmodule NeuZeitWeb.Stories.Toolbar do
  use PhoenixStorybook.Story, :example
  use Gettext, backend: NeuZeitWeb.Gettext
  import NeuZeitWeb.CoreComponents, only: [input: 1]
  import NeuZeitWeb.UI.Toolbar, only: [toolbar: 1]

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, teacher: "", unplaced: false)}

  @impl true
  def handle_event("filter", params, socket),
    do:
      {:noreply,
       assign(socket, teacher: params["teacher"], unplaced: params["unplaced"] == "true")}

  def handle_event("reset", _params, socket),
    do: {:noreply, assign(socket, teacher: "", unplaced: false)}

  @impl true
  def render(assigns) do
    ~H"""
    <form id="example-filters" phx-change="filter">
      <.toolbar>
        <.input
          type="select"
          name="teacher"
          value={@teacher}
          label={gettext("Teacher")}
          options={[{gettext("All teachers"), ""}, {"Anna Weber", "anna"}]}
        />
        <.input type="checkbox" name="unplaced" checked={@unplaced} label={gettext("Unplaced only")} />
        <:actions>
          <button type="button" class="btn" phx-click="reset">{gettext("Reset filters")}</button>
        </:actions>
      </.toolbar>
    </form>
    """
  end
end
