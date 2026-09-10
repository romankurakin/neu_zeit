defmodule NeuZeitWeb.ExceptionLive.Index do
  @moduledoc """
  Edits dated changes to a published timetable.

  Each change requires a reason and author. Reverting a change keeps its history.
  Moves and additions cannot target non-teaching dates. A meeting can be moved
  from a non-teaching date to a teaching date.
  """
  use NeuZeitWeb, :live_view

  alias NeuZeit.{Catalog, Planning}
  alias NeuZeit.Planning.ScheduleException
  alias NeuZeitWeb.Nav

  @impl true
  def mount(%{"term_id" => term_id}, _session, socket) do
    term = Catalog.get_term!(term_id)

    {:ok,
     socket
     |> assign(:page_title, gettext("One-off changes"))
     |> assign(:term, term)
     |> assign(:terms, Catalog.list_terms())
     |> assign(:grid, NeuZeit.Config.grid!())
     |> assign(:sessions, Catalog.list_sessions(term_id))
     |> assign(:rooms, Catalog.list_rooms())
     |> assign(:reverting, nil)
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = Nav.assign_return(socket, params)
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, params) do
    exception = %ScheduleException{
      term_id: socket.assigns.term.id,
      kind: params["kind"] || "cancel",
      session_id: params["session_id"],
      occurrence_date: parse_date(params["date"]),
      new_date: if(params["kind"] != "cancel", do: parse_date(params["new_date"])),
      new_slot: if(params["kind"] != "cancel", do: parse_slot(params["new_slot"])),
      new_room_id: if(params["kind"] != "cancel", do: params["new_room_id"])
    }

    socket
    |> assign(:editing, exception)
    |> assign(:form, to_form(Planning.change_schedule_exception(exception)))
  end

  defp apply_action(socket, :edit, %{"id" => id} = params) do
    exception = Planning.get_schedule_exception!(id, socket.assigns.term.id)

    attrs =
      Map.take(params, ["kind", "new_date"])
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Map.new()

    attrs =
      if attrs["kind"] == "cancel",
        do: Map.merge(attrs, %{"new_date" => nil, "new_slot" => nil, "new_room_id" => nil}),
        else: attrs

    # An addition has one real date, including legacy API records that used
    # new_date. Dragging such an addition edits that date in the same record.
    attrs =
      if (attrs["kind"] || exception.kind) == "add" do
        Map.merge(attrs, %{
          "occurrence_date" =>
            attrs["new_date"] || exception.new_date || exception.occurrence_date,
          "new_date" => nil
        })
      else
        attrs
      end

    socket
    |> assign(:editing, exception)
    |> assign(:form, to_form(Planning.change_schedule_exception(exception, attrs)))
  end

  defp apply_action(socket, :index, _params),
    do: socket |> assign(:editing, nil) |> assign(:form, nil)

  defp parse_slot(nil), do: nil

  defp parse_slot(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_date(nil), do: nil

  defp parse_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _invalid -> nil
    end
  end

  @impl true
  def handle_event("validate", %{"schedule_exception" => params}, socket) do
    params =
      if params["kind"] == "cancel",
        do: Map.merge(params, %{"new_date" => nil, "new_slot" => nil, "new_room_id" => nil}),
        else: params

    params = if params["kind"] == "add", do: Map.put(params, "new_date", nil), else: params
    changeset = Planning.change_schedule_exception(socket.assigns.editing, params)
    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"schedule_exception" => params}, socket) do
    attrs = Map.put(params, "term_id", socket.assigns.term.id)

    attrs =
      if attrs["kind"] == "cancel",
        do: Map.merge(attrs, %{"new_date" => nil, "new_slot" => nil, "new_room_id" => nil}),
        else: attrs

    attrs = if attrs["kind"] == "add", do: Map.put(attrs, "new_date", nil), else: attrs

    result =
      if socket.assigns.editing.id do
        Planning.update_schedule_exception(
          socket.assigns.editing,
          Map.drop(attrs, ["term_id", "session_id"])
        )
      else
        if Enum.any?(socket.assigns.sessions, &(&1.id == attrs["session_id"])),
          do: Planning.create_schedule_exception(attrs),
          else:
            {:error,
             Catalog.error_changeset(
               %ScheduleException{},
               :session_id,
               "must belong to this term"
             )}
      end

    case result do
      {:ok, _exception} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Change saved."))
         |> finish_edit()
         |> load()}

      {:error, reason} ->
        # Show the reason when a date change is rejected.
        {:noreply, Errors.put(socket, reason, as: :form)}
    end
  end

  def handle_event("revert_prompt", %{"id" => id}, socket),
    do:
      {:noreply,
       assign(socket, :reverting, Planning.get_schedule_exception!(id, socket.assigns.term.id))}

  def handle_event("revert_cancel", _params, socket),
    do: {:noreply, assign(socket, :reverting, nil)}

  def handle_event("revert_confirm", _params, socket) do
    case Planning.update_schedule_exception(socket.assigns.reverting, %{"status" => "reverted"}) do
      {:ok, _exception} ->
        {:noreply,
         socket
         |> assign(:reverting, nil)
         |> put_flash(:info, gettext("Change reverted. Its history is kept."))
         |> finish_edit()
         |> load()}

      {:error, reason} ->
        {:noreply, socket |> assign(:reverting, nil) |> Errors.put(reason)}
    end
  end

  defp finish_edit(socket) do
    if socket.assigns.return_to,
      do: push_navigate(socket, to: socket.assigns.return_to),
      else: push_patch(socket, to: ~p"/terms/#{socket.assigns.term}/exceptions")
  end

  defp load(socket) do
    placement_weeks =
      case Enum.find(Planning.list_plans(socket.assigns.term.id), &(&1.status == "active")) do
        nil -> %{}
        plan -> Map.new(Planning.get_plan!(plan.id).placements, &{&1.session_id, &1.week_mask})
      end

    socket
    |> assign(:placement_weeks, placement_weeks)
    |> assign(:exceptions, Planning.list_schedule_exceptions(socket.assigns.term.id))
  end

  defp session_label(session, index, total, placement_weeks) do
    weeks =
      Map.get(
        placement_weeks,
        session.id,
        if(session.automatic_weeks, do: [], else: session.week_mask)
      )

    [
      session.course_component.course.code,
      component_kind_label(session.course_component.kind),
      session.teacher.name,
      Enum.map_join(session.cohorts, ", ", & &1.name),
      if(weeks != [], do: weeks_label(weeks, total)),
      ngettext("%{count} time slot", "%{count} time slots", session.duration_slots,
        count: session.duration_slots
      ),
      gettext("Block %{n}", n: index)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(", ")
  end

  defp change_action("cancel"), do: gettext("Cancel dated session")
  defp change_action("move"), do: gettext("Move dated session")
  defp change_action("add"), do: gettext("Add a dated session")
  defp change_action(_kind), do: gettext("Record a change")

  defp kind_label("cancel"), do: gettext("Cancelled")
  defp kind_label("move"), do: gettext("Moved")
  defp kind_label("add"), do: gettext("Added")
  defp kind_label(kind), do: kind

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={Nav.sections(@term)}
      current_path={~p"/terms/#{@term}/exceptions"}
      terms={@terms}
      current_term={@term}
    >
      <.link :if={@return_to} navigate={@return_to} class="btn mb-4">{gettext("Return to timetable")}</.link>
      <.page_header title={gettext("One-off changes")}>
        <:actions>
          <.link patch={~p"/terms/#{@term}/exceptions/new"} class="btn btn-primary">
            <.icon name="hero-plus" class="size-4" /> {gettext("Record a change")}
          </.link>
        </:actions>
      </.page_header>

      <div class={["grid gap-4", @editing && "lg:grid-cols-[2fr_1fr]"]}>
        <div class="min-w-0">
          <.empty_state
            :if={@exceptions == []}
            title={gettext("No one-off changes")}
            icon="hero-calendar-days"
          />

          <.table
            :if={@exceptions != []}
            id="exceptions"
            rows={@exceptions}
            row_id={&"exception-#{&1.id}"}
          >
            <:col :let={row} label={gettext("Change")}>
              {kind_label(row.kind)}
            </:col>
            <:col :let={row} label={gettext("Session")}>
              {session_label(
                row.session,
                (Enum.find_index(@sessions, &(&1.id == row.session_id)) || 0) + 1,
                @term.weeks_count,
                @placement_weeks
              )}
            </:col>
            <:col :let={row} label={gettext("Date")}>{row.occurrence_date}</:col>
            <:col :let={row} label={gettext("Moved to")}>
              <span :if={row.new_date}>{row.new_date}</span>
              <span :if={row.new_slot}>{NeuZeitWeb.Scheduling.SessionCard.time_range(
                @grid,
                row.new_slot,
                row.session.duration_slots
              )}</span>
              <span :if={row.new_room} class="text-base-content">, {row.new_room.name}</span>
            </:col>
            <:col :let={row} label={gettext("Reason")}>{row.reason}</:col>
            <:col :let={row} label={gettext("Author")}>{row.created_by}</:col>
            <:col :let={row} label={gettext("Status")}>
              <.status_indicator
                status={if row.status == "active", do: :active, else: :unknown}
                label={
                  if row.status == "active", do: gettext("In force"), else: gettext("Change reverted")
                }
              />
            </:col>
            <:action :let={row}>
              <.link
                :if={row.status == "active"}
                patch={~p"/terms/#{@term}/exceptions/#{row.id}/edit?return_to=#{@return_to || ""}"}
                class="btn btn-ghost"
              >{gettext("Edit")}</.link>
              <button
                :if={row.status == "active"}
                class="btn btn-ghost"
                phx-click="revert_prompt"
                phx-value-id={row.id}
              >
                {gettext("Revert change")}
              </button>
            </:action>
          </.table>
        </div>

        <.details_panel
          :if={@editing}
          class="order-first lg:order-last"
          title={
            if @editing.id,
              do: gettext("Edit change"),
              else: change_action(to_string(@form[:kind].value))
          }
          on_close={JS.patch(~p"/terms/#{@term}/exceptions")}
        >
          <.form
            for={@form}
            id="exception-form"
            phx-mounted={JS.focus_first(to: "#exception-form")}
            phx-change="validate"
            phx-submit="save"
            class="flex flex-col gap-2"
          >
            <.input
              field={@form[:session_id]}
              disabled={@editing.id != nil}
              type="select"
              label={gettext("Session")}
              prompt={gettext("Choose a session")}
              options={
                Enum.map(Enum.with_index(@sessions, 1), fn {s, index} ->
                  {session_label(s, index, @term.weeks_count, @placement_weeks), s.id}
                end)
              }
            />
            <.input
              field={@form[:kind]}
              type="select"
              label={gettext("Change")}
              options={[
                {gettext("Cancel dated session"), "cancel"},
                {gettext("Move dated session"), "move"},
                {gettext("Add a dated session"), "add"}
              ]}
            />
            <.date_field
              field={@form[:occurrence_date]}
              label={gettext("Date")}
              min={@term.starts_on}
              max={@term.ends_on}
            />

            <div :if={to_string(@form[:kind].value) in ["move", "add"]} class="flex flex-col gap-2">
              <.date_field
                :if={to_string(@form[:kind].value) == "move"}
                field={@form[:new_date]}
                label={gettext("New date")}
                min={@term.starts_on}
                max={@term.ends_on}
                disallowed={@term.excluded_dates || []}
              />
              <.input
                field={@form[:new_slot]}
                type="select"
                label={
                  if to_string(@form[:kind].value) == "move",
                    do: gettext("New time"),
                    else: gettext("Time")
                }
                prompt={gettext("Choose a time")}
                options={slot_options(@grid)}
              />
              <.input
                field={@form[:new_room_id]}
                type="select"
                label={
                  if to_string(@form[:kind].value) == "move",
                    do: gettext("New room"),
                    else: gettext("Room")
                }
                prompt={gettext("Choose a room")}
                options={Enum.map(@rooms, &{"#{&1.name}, #{&1.building.name}", &1.id})}
              />
            </div>

            <.input field={@form[:reason]} type="text" label={gettext("Reason")} required />
            <.input field={@form[:created_by]} type="text" label={gettext("Author")} required />

            <p class="type-detail font-semibold">
              {gettext("Applies only to this date. The semester template stays the same.")}
            </p>
            <div class="flex flex-wrap gap-2 pt-2">
              <.button variant="primary" phx-disable-with={gettext("Saving")}>
                {if @editing.id,
                  do: gettext("Save"),
                  else: change_action(to_string(@form[:kind].value))}
              </.button>
              <.link patch={~p"/terms/#{@term}/exceptions"} class="btn btn-ghost">
                {gettext("Cancel")}
              </.link>
            </div>
          </.form>
          <button
            :if={@editing.id && @editing.status == "active"}
            class="btn"
            phx-click="revert_prompt"
            phx-value-id={@editing.id}
          >{gettext("Revert change")}</button>
        </.details_panel>
      </div>

      <.alert_dialog
        :if={@reverting}
        title={gettext("Revert this change?")}
        message={gettext("The change will no longer apply. Its record will remain in the history.")}
        confirm_label={gettext("Revert change")}
        on_confirm="revert_confirm"
        on_cancel="revert_cancel"
        variant="primary"
      />
    </Layouts.app>
    """
  end

  defp slot_options(grid) do
    grid.slots
    |> Enum.with_index(1)
    |> Enum.map(fn {slot, index} -> {"#{index}, #{slot.start}", index} end)
  end
end
