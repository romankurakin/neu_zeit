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
     |> assign(:grid, NeuZeit.Config.grid!())
     |> assign(:teachers, Catalog.list_teachers())
     |> assign(:usage, Catalog.usage_counts(term_id).teachers)
     |> assign(:selected, nil)
     |> assign(:cells, [])}
  end

  @impl true
  def handle_params(%{"teacher_id" => teacher_id} = params, _uri, socket) do
    teacher = Catalog.get_teacher!(teacher_id)

    {:noreply,
     socket
     |> Nav.assign_return(params)
     |> assign(:selected, teacher)
     |> assign(:cells, Catalog.list_teacher_availability(socket.assigns.term.id, teacher.id))}
  end

  def handle_params(params, _uri, socket),
    do:
      {:noreply,
       socket |> Nav.assign_return(params) |> assign(:selected, nil) |> assign(:cells, [])}

  @impl true
  def handle_event("grid_changed", %{"cells" => cells}, socket) do
    teacher = socket.assigns.selected
    cells = Enum.map(cells, &%{"day" => &1["day"], "slot" => &1["slot"]})

    case Catalog.replace_teacher_availability(socket.assigns.term.id, teacher.id, cells) do
      {:ok, saved} ->
        {:reply, %{cells: Enum.map(saved, &Map.take(&1, [:day, :slot]))},
         assign(socket, :cells, saved)}

      {:error, reason} ->
        # A same-value assign produces no DOM diff. Explicitly acknowledge the
        # stored cells so optimistic painting also rolls back after a refusal.
        saved = Catalog.list_teacher_availability(socket.assigns.term.id, teacher.id)

        {:reply, %{cells: Enum.map(saved, &Map.take(&1, [:day, :slot]))},
         socket
         |> assign(:cells, saved)
         |> Errors.put(reason)}
    end
  end

  def handle_event("clear", _params, socket) do
    teacher = socket.assigns.selected

    case Catalog.replace_teacher_availability(socket.assigns.term.id, teacher.id, []) do
      {:ok, _cells} ->
        {:noreply,
         socket
         |> assign(:cells, [])
         |> put_flash(:info, gettext("%{name} is now unrestricted.", name: teacher.name))}

      {:error, reason} ->
        {:noreply, Errors.put(socket, reason)}
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
      <.link :if={@return_to} navigate={@return_to} class="btn mb-4">{gettext("Return to timetable")}</.link>
      <.page_header
        title={gettext("Teacher availability")}
        subtitle={
          gettext("Select available times. An empty grid allows any time.")
        }
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
                  ngettext("%{count} time slot allowed", "%{count} time slots allowed", length(@cells),
                    count: length(@cells)
                  ),
                else: gettext("Any time is allowed.")
            }
          />

          <div :if={restricted?(@cells)} class="alert alert-info mt-4">
            <.icon name="hero-information-circle" class="size-5" />
            <span>
              {gettext(
                "The teacher must be available for the full session."
              )}
            </span>
          </div>

          <:actions>
            <.link navigate={~p"/terms/#{@term}/sessions?teacher_id=#{@selected.id}"} class="btn">{gettext("Sessions")}</.link>
            <button :if={restricted?(@cells)} class="btn" phx-click="clear">
              {gettext("Remove restriction")}
            </button>
          </:actions>
        </.details_panel>
      </div>
    </Layouts.app>
    """
  end
end
