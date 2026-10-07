defmodule NeuZeitWeb.AvailabilityLive.Index do
  @moduledoc """
  Edits recurring teacher availability for one term.

  An empty selection allows any time. The context rejects changes that remove
  all valid starts or conflict with existing placements or dated changes.
  """
  use NeuZeitWeb, :live_view

  alias NeuZeit.Catalog
  alias NeuZeitWeb.Nav

  @impl true
  def mount(%{"term_id" => term_id}, _session, socket) do
    term = Catalog.get_term!(term_id)

    {:ok,
     socket
     |> assign(:page_title, gettext("Availability"))
     |> assign(:term, term)
     |> assign(:terms, Catalog.list_terms())
     |> assign(:grid, NeuZeit.Config.grid!(term))
     |> assign(:teachers, Catalog.list_teachers())
     |> assign(:usage, Catalog.usage_counts(term_id).teachers)
     |> assign(:selected, nil)
     |> assign(:clearing, false)
     |> assign(:saved, false)
     |> assign(:cells, [])}
  end

  @impl true
  def handle_params(%{"teacher_id" => teacher_id} = params, _uri, socket) do
    teacher = Catalog.get_teacher!(teacher_id)

    {:noreply,
     socket
     |> Nav.assign_return(params)
     |> assign(:selected, teacher)
     |> assign(:clearing, false)
     |> assign(:saved, false)
     |> assign(:cells, Catalog.list_teacher_availability(socket.assigns.term.id, teacher.id))}
  end

  def handle_params(params, _uri, socket),
    do:
      {:noreply,
       socket
       |> Nav.assign_return(params)
       |> assign(:selected, nil)
       |> assign(:clearing, false)
       |> assign(:saved, false)
       |> assign(:cells, [])}

  @impl true
  def handle_event("grid_changed", params, socket) do
    teacher = socket.assigns.selected
    cells = apply_cells(socket.assigns.cells, params)

    case Catalog.replace_teacher_availability(socket.assigns.term.id, teacher.id, cells) do
      {:ok, saved} ->
        {:noreply, socket |> assign(:cells, saved) |> assign(:saved, true)}

      {:error, reason} ->
        # The assigns still hold the stored cells, so a refusal renders them again.
        {:noreply, Errors.put(socket, reason)}
    end
  end

  def handle_event("clear_prompt", _params, socket),
    do: {:noreply, assign(socket, :clearing, true)}

  def handle_event("clear_cancel", _params, socket),
    do: {:noreply, assign(socket, :clearing, false)}

  def handle_event("clear_confirm", _params, socket) do
    teacher = socket.assigns.selected

    case Catalog.replace_teacher_availability(socket.assigns.term.id, teacher.id, []) do
      {:ok, _cells} ->
        {:noreply,
         socket
         |> assign(:cells, [])
         |> assign(:clearing, false)
         |> put_flash(:info, gettext("%{name} is now unrestricted.", name: teacher.name))}

      {:error, reason} ->
        {:noreply, socket |> assign(:clearing, false) |> Errors.put(reason)}
    end
  end

  defp restricted?(cells), do: cells != []

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={Nav.sections(@term)}
      current_path={~p"/terms/#{@term}/availability"}
      terms={@terms}
      current_term={@term}
    >
      <.link :if={@return_to} navigate={@return_to} class="btn mb-4">
        {Nav.return_label(@return_to)}
      </.link>
      <.page_header
        title={gettext("Availability")}
        subtitle={gettext("Select available times. An empty grid allows any time.")}
      />

      <div class="grid min-w-0 gap-4 lg:grid-cols-[1fr_2fr]">
        <.card title={gettext("Teachers")}>
          <ul class="menu w-full p-0">
            <li :for={teacher <- @teachers} id={"teacher-#{teacher.id}"}>
              <.link
                patch={~p"/terms/#{@term}/availability/#{teacher}"}
                class={["justify-between", @selected && @selected.id == teacher.id && "menu-active"]}
              >
                <span>{teacher.name}</span>
                <span class="type-detail text-base-content">
                  {ngettext("%{count} session", "%{count} sessions", Map.get(@usage, teacher.id, 0),
                    count: Map.get(@usage, teacher.id, 0)
                  )}
                </span>
              </.link>
            </li>
          </ul>
        </.card>

        <.empty_state
          :if={is_nil(@selected)}
          title={gettext("Choose a teacher")}
          message={gettext("Pick a teacher in the list to set the times they can teach.")}
          icon="hero-clock"
        />

        <.details_panel
          :if={@selected}
          id="availability-inspector"
          class="order-first lg:order-last"
          phx-mounted={JS.focus_first(to: "#availability-inspector")}
          title={@selected.name}
          on_close={JS.patch(~p"/terms/#{@term}/availability")}
        >
          <.time_grid
            id={"availability-#{@selected.id}"}
            cells={@cells}
            grid={@grid}
            legend={
              if restricted?(@cells),
                do:
                  ngettext(
                    "%{count} time slot allowed",
                    "%{count} time slots allowed",
                    length(@cells),
                    count: length(@cells)
                  ),
                else: gettext("Any time is allowed.")
            }
          />
          <p :if={@saved} role="status" class="mt-1 type-detail text-success">{gettext("Saved")}</p>

          <div :if={restricted?(@cells)} class="alert alert-info mt-4">
            <.icon name="hero-information-circle" class="size-5" />
            <span>
              {gettext("The teacher must be available for the full session.")}
            </span>
          </div>

          <:actions>
            <.link navigate={~p"/terms/#{@term}/sessions?teacher_id=#{@selected.id}"} class="btn">{gettext(
              "Sessions"
            )}</.link>
            <button :if={restricted?(@cells)} class="btn" phx-click="clear_prompt">
              {gettext("Remove restriction")}
            </button>
          </:actions>
        </.details_panel>
      </div>

      <.alert_dialog
        :if={@clearing}
        title={gettext("Remove the restriction for %{name}?", name: @selected.name)}
        message={gettext("Any time will be allowed again.")}
        confirm_label={gettext("Remove restriction")}
        on_confirm="clear_confirm"
        on_cancel="clear_cancel"
      />
    </Layouts.app>
    """
  end
end
