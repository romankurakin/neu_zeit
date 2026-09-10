defmodule NeuZeitWeb.Stories.TransferList do
  use PhoenixStorybook.Story, :example
  use Gettext, backend: NeuZeitWeb.Gettext
  import NeuZeitWeb.UI.TransferList, only: [transfer_list: 1]

  @impl true
  def mount(_params, _session, socket) do
    rooms =
      for {name, building} <- [
            {"101", "Hauptgebäude"},
            {"102", "Hauptgebäude"},
            {"L12", "Ingenieurgebäude"},
            {"Sporthalle", "Hauptgebäude"}
          ],
          do: %{id: name, label: name, hint: building}

    {:ok, assign(socket, rooms: rooms, selected_room_ids: ["101", "102"])}
  end

  @impl true
  def handle_event("selection_changed", %{"selected" => selected}, socket),
    do: {:noreply, assign(socket, :selected_room_ids, selected)}

  @impl true
  def render(assigns) do
    ~H"""
    <.transfer_list
      id="room-selection"
      available={Enum.reject(@rooms, &(&1.id in @selected_room_ids))}
      selected={Enum.filter(@rooms, &(&1.id in @selected_room_ids))}
      available_label={gettext("Other rooms")}
      selected_label={gettext("Allowed rooms")}
    />
    """
  end
end
