defmodule NeuZeitWeb.Stories.TimeGrid do
  use PhoenixStorybook.Story, :example
  use Gettext, backend: NeuZeitWeb.Gettext
  import NeuZeitWeb.Scheduling.TimeGrid, only: [apply_cells: 2, time_grid: 1]

  @impl true
  def mount(_params, _session, socket),
    do:
      {:ok,
       assign(socket,
         cells: [%{day: 1, slot: 1}, %{day: 1, slot: 2}, %{day: 3, slot: 4}],
         readonly: false
       )}

  @impl true
  def handle_event("grid_changed", params, socket),
    do: {:noreply, assign(socket, :cells, apply_cells(socket.assigns.cells, params))}

  def handle_event("toggle_readonly", _params, socket),
    do: {:noreply, update(socket, :readonly, &(!&1))}

  @impl true
  def render(assigns) do
    ~H"""
    <button
      type="button"
      class="btn mb-4"
      phx-click="toggle_readonly"
      aria-pressed={to_string(@readonly)}
    >Read only</button>
    <.time_grid
      id="availability-grid"
      cells={@cells}
      readonly={@readonly}
      legend={ngettext("%{count} selected time slot", "%{count} selected time slots", length(@cells))}
    />
    """
  end
end
