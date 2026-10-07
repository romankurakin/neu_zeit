defmodule NeuZeitWeb.RoomLive.Index do
  @moduledoc """
  Edits buildings and rooms, and shows room usage.

  Names with non-numeric characters prompt a building review.
  The assigned `building_id` determines the building used in scheduling.
  """
  use NeuZeitWeb, :live_view

  alias NeuZeit.Catalog
  alias NeuZeit.Catalog.{Building, Room}
  alias NeuZeitWeb.Nav

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Rooms"))
     |> assign(:building_filter, "all")
     |> assign(:deleting, nil)
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = Nav.assign_return(socket, params)
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new_building, _params) do
    assign_form(socket, :building, %Building{}, Catalog.change_building(%Building{}))
  end

  defp apply_action(socket, :edit_building, %{"id" => id}) do
    building = Catalog.get_building!(id)
    assign_form(socket, :building, building, Catalog.change_building(building))
  end

  defp apply_action(socket, :new_room, _params) do
    assign_form(socket, :room, %Room{}, Catalog.change_room(%Room{}))
  end

  defp apply_action(socket, :edit_room, %{"id" => id}) do
    room = Catalog.get_room!(id)
    assign_form(socket, :room, room, Catalog.change_room(room))
  end

  defp apply_action(socket, :index, _params) do
    socket |> assign(:editing, nil) |> assign(:kind, nil) |> assign(:form, nil)
  end

  defp assign_form(socket, kind, record, changeset) do
    socket
    |> assign(:kind, kind)
    |> assign(:editing, record)
    |> assign(:form, to_form(changeset))
  end

  @impl true
  def handle_event("filter_building", %{"building_id" => id}, socket) do
    {:noreply, assign(socket, :building_filter, id)}
  end

  def handle_event("validate", %{"building" => params}, socket) do
    {:noreply,
     assign(
       socket,
       :form,
       to_form(Catalog.change_building(socket.assigns.editing, params), action: :validate)
     )}
  end

  def handle_event("validate", %{"room" => params}, socket) do
    {:noreply,
     assign(
       socket,
       :form,
       to_form(Catalog.change_room(socket.assigns.editing, params), action: :validate)
     )}
  end

  def handle_event("save", %{"building" => params}, socket) do
    result =
      case socket.assigns.editing do
        %Building{id: nil} -> Catalog.create_building(params)
        building -> Catalog.update_building(building, params)
      end

    persist(socket, result)
  end

  def handle_event("save", %{"room" => params}, socket) do
    result =
      case socket.assigns.editing do
        %Room{id: nil} -> Catalog.create_room(params)
        room -> Catalog.update_room(room, params)
      end

    persist(socket, result)
  end

  def handle_event("delete_prompt", %{"kind" => "building", "id" => id}, socket) do
    {:noreply, assign(socket, :deleting, Catalog.get_building!(id))}
  end

  def handle_event("delete_prompt", %{"id" => id}, socket) do
    {:noreply, assign(socket, :deleting, Catalog.get_room!(id))}
  end

  def handle_event("delete_cancel", _params, socket),
    do: {:noreply, assign(socket, :deleting, nil)}

  def handle_event("delete_confirm", _params, socket) do
    case delete(socket.assigns.deleting) do
      {:ok, record} ->
        {:noreply,
         socket
         |> assign(:deleting, nil)
         |> put_flash(:info, gettext("Deleted %{name}.", name: record.name))
         |> load()}

      {:error, reason} ->
        {:noreply, socket |> assign(:deleting, nil) |> Errors.put(reason)}
    end
  end

  # The list disables deletion of used records; this catches a concurrent change.
  defp delete(%Building{} = building), do: Catalog.delete_building(building)

  defp delete(%Room{} = room) do
    Catalog.delete_room(room)
  rescue
    Ecto.ConstraintError ->
      {:error,
       {:conflict,
        gettext("%{name} is used by a teaching type or a scheduled session.", name: room.name)}}
  end

  defp persist(socket, {:ok, record}) do
    {:noreply,
     socket
     |> put_flash(:info, gettext("Saved %{name}.", name: record.name))
     |> push_patch(to: ~p"/rooms")
     |> load()}
  end

  defp persist(socket, {:error, reason}) do
    {:noreply, Errors.put(socket, reason, as: :form)}
  end

  defp load(socket) do
    socket
    |> assign(:buildings, Catalog.list_buildings())
    |> assign(:rooms, Catalog.list_rooms())
    |> assign(:usage, Catalog.usage_counts().rooms)
    |> assign(:building_usage, Catalog.building_usage())
  end

  # Flag names with non-numeric characters for building review. This does not verify the building.
  defp conventional?(room), do: Regex.match?(~r/^\d+$/, room.name)

  defp visible_rooms(rooms, "all"), do: rooms
  defp visible_rooms(rooms, building_id), do: Enum.filter(rooms, &(&1.building_id == building_id))

  # Names the reference that prevents deletion, or nil when the record is free.
  defp room_blocker(usage, room) do
    components = get_in(usage, [room.id, :components]) || 0
    placements = get_in(usage, [room.id, :placements]) || 0

    cond do
      components > 0 ->
        ngettext(
          "Allowed for %{count} teaching type",
          "Allowed for %{count} teaching types",
          components,
          count: components
        )

      placements > 0 ->
        ngettext("Used by %{count} placement", "Used by %{count} placements", placements,
          count: placements
        )

      true ->
        nil
    end
  end

  defp building_blocker(usage, building) do
    case Map.get(usage, building.id, 0) do
      0 -> nil
      count -> ngettext("Has %{count} room", "Has %{count} rooms", count, count: count)
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :visible, visible_rooms(assigns.rooms, assigns.building_filter))

    ~H"""
    <Layouts.app
      flash={@flash}
      nav={Nav.sections(@navigation_term)}
      current_path={~p"/rooms"}
      terms={@navigation_terms}
      current_term={@navigation_term}
    >
      <.link :if={@return_to} navigate={@return_to} class="btn mb-4">
        {Nav.return_label(@return_to)}
      </.link>
      <.page_header
        title={gettext("Rooms")}
        subtitle={
          gettext(
            "Capacity and equipment are not checked automatically. Include only suitable rooms."
          )
        }
      >
        <:actions>
          <.link patch={~p"/rooms/buildings/new"} class="btn">{gettext("New building")}</.link>
          <.link patch={~p"/rooms/new"} class="btn btn-primary">
            <.icon name="hero-plus" class="size-4" /> {gettext("New room")}
          </.link>
        </:actions>
      </.page_header>

      <div class="mb-4 grid gap-4 sm:grid-cols-3">
        <.stat_card label={gettext("Buildings")} value={length(@buildings)} />
        <.stat_card label={gettext("Rooms")} value={length(@rooms)} />
        <.stat_card
          label={gettext("Rooms to review")}
          value={Enum.count(@rooms, &(not conventional?(&1)))}
          status={if Enum.any?(@rooms, &(not conventional?(&1))), do: :warning, else: :ok}
          hint={gettext("names containing letters or other characters")}
        />
      </div>

      <div class={["grid gap-4", @editing && "lg:grid-cols-[2fr_1fr]"]}>
        <div class="flex min-w-0 flex-col gap-6">
          <.empty_state
            :if={@buildings == []}
            title={gettext("No buildings yet")}
            message={gettext("Create a building first, then add its rooms.")}
            icon="hero-building-office-2"
          >
            <:actions>
              <.link patch={~p"/rooms/buildings/new"} class="btn btn-primary">
                {gettext("New building")}
              </.link>
            </:actions>
          </.empty_state>

          <.empty_state
            :if={@buildings != [] and @rooms == []}
            title={gettext("No rooms yet")}
            message={gettext("Add the rooms that sessions can use.")}
            icon="hero-building-office-2"
          >
            <:actions>
              <.link patch={~p"/rooms/new"} class="btn btn-primary">{gettext("New room")}</.link>
            </:actions>
          </.empty_state>

          <div :if={@rooms != []}>
            <.toolbar>
              <form phx-change="filter_building" id="building-filter">
                <select name="building_id" class="select select-bordered">
                  <option value="all" selected={@building_filter == "all"}>
                    {gettext("All buildings")}
                  </option>
                  <option
                    :for={building <- @buildings}
                    value={building.id}
                    selected={@building_filter == building.id}
                  >
                    {building.name}
                  </option>
                </select>
              </form>
              <span class="type-detail text-base-content">
                {ngettext("%{count} room", "%{count} rooms", length(@visible),
                  count: length(@visible)
                )}
              </span>
            </.toolbar>

            <.table
              id="rooms"
              rows={@visible}
              row_id={&"room-#{&1.id}"}
              empty_message={gettext("No rooms in this building yet.")}
            >
              <:col :let={room} label={gettext("Room")}>
                <span class="font-semibold">{room.name}</span>
              </:col>
              <:col :let={room} label={gettext("Building")}>{room.building.name}</:col>
              <:col :let={room} label={gettext("Allowed for")}>
                {ngettext(
                  "%{count} teaching type",
                  "%{count} teaching types",
                  get_in(@usage, [room.id, :components]) || 0,
                  count: get_in(@usage, [room.id, :components]) || 0
                )}
              </:col>
              <:col :let={room} label={gettext("Placements")} numeric>
                {get_in(@usage, [room.id, :placements]) || 0}
              </:col>
              <:col :let={room} label={gettext("Room designation")}>
                <span :if={not conventional?(room)}>{gettext("Check building")}</span>
                <span :if={conventional?(room)} class="type-detail text-base-content">
                  {gettext("Number only")}
                </span>
              </:col>
              <:action :let={room}>
                <.link patch={~p"/rooms/#{room}/edit"} class="btn btn-ghost">{gettext("Edit")}</.link>
                <button
                  class="btn btn-ghost text-error"
                  phx-click="delete_prompt"
                  phx-value-id={room.id}
                  disabled={room_blocker(@usage, room) != nil}
                  title={room_blocker(@usage, room)}
                >
                  {gettext("Delete")}
                </button>
              </:action>
            </.table>
          </div>

          <div :if={@buildings != []}>
            <h2 class="mb-2 type-heading">{gettext("Buildings")}</h2>
            <.table id="buildings" rows={@buildings} row_id={&"building-#{&1.id}"}>
              <:col :let={building} label={gettext("Building")}>
                <span class="font-semibold">{building.name}</span>
              </:col>
              <:col :let={building} label={gettext("Rooms")} numeric>
                {Map.get(@building_usage, building.id, 0)}
              </:col>
              <:action :let={building}>
                <.link patch={~p"/rooms/buildings/#{building}/edit"} class="btn btn-ghost">
                  {gettext("Edit")}
                </.link>
                <button
                  class="btn btn-ghost text-error"
                  phx-click="delete_prompt"
                  phx-value-kind="building"
                  phx-value-id={building.id}
                  disabled={building_blocker(@building_usage, building) != nil}
                  title={building_blocker(@building_usage, building)}
                >
                  {gettext("Delete")}
                </button>
              </:action>
            </.table>
          </div>
        </div>

        <.details_panel
          :if={@editing}
          class="order-first lg:order-last"
          title={inspector_title(@kind, @editing)}
          on_close={JS.patch(~p"/rooms")}
        >
          <.form
            :if={@kind == :building}
            for={@form}
            id="building-form"
            phx-mounted={JS.focus_first(to: "#building-form")}
            phx-change="validate"
            phx-submit="save"
          >
            <.input field={@form[:name]} type="text" label={gettext("Building name")} />
            <div class="flex gap-2 pt-2">
              <.button variant="primary" phx-disable-with={gettext("Saving")}>{gettext("Save")}</.button>
              <.link patch={~p"/rooms"} class="btn btn-ghost">{gettext("Cancel")}</.link>
            </div>
          </.form>

          <.form
            :if={@kind == :room}
            for={@form}
            id="room-form"
            phx-mounted={JS.focus_first(to: "#room-form")}
            phx-change="validate"
            phx-submit="save"
          >
            <.input field={@form[:name]} type="text" label={gettext("Room name")} />
            <.input
              field={@form[:building_id]}
              type="select"
              label={gettext("Building")}
              prompt={gettext("Choose a building")}
              options={Enum.map(@buildings, &{&1.name, &1.id})}
            />
            <div class="flex gap-2 pt-2">
              <.button variant="primary" phx-disable-with={gettext("Saving")}>{gettext("Save")}</.button>
              <.link patch={~p"/rooms"} class="btn btn-ghost">{gettext("Cancel")}</.link>
            </div>
          </.form>
        </.details_panel>
      </div>

      <.alert_dialog
        :if={@deleting}
        title={gettext("Delete %{name}?", name: @deleting.name)}
        message={delete_message(@deleting)}
        confirm_label={gettext("Delete")}
        on_confirm="delete_confirm"
        on_cancel="delete_cancel"
      />
    </Layouts.app>
    """
  end

  defp delete_message(%Building{name: name}),
    do: gettext("Deletes the building %{name}. This cannot be undone.", name: name)

  defp delete_message(%Room{name: name}),
    do: gettext("Deletes the room %{name}. This cannot be undone.", name: name)

  defp inspector_title(:building, %Building{id: nil}), do: gettext("New building")
  defp inspector_title(:building, _record), do: gettext("Edit building")
  defp inspector_title(:room, %Room{id: nil}), do: gettext("New room")
  defp inspector_title(:room, _record), do: gettext("Edit room")
end
