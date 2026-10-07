defmodule NeuZeitWeb.ExceptionLive.Index do
  @moduledoc """
  Lists and edits one-off changes to the active plan.

  Each change requires a reason and author. Reverting a change keeps its history.
  Moves and additions cannot target non-teaching dates. A dated session can be
  moved from a non-teaching date to a teaching date.
  """
  use NeuZeitWeb, :live_view

  alias NeuZeit.{Catalog, Planning}
  alias NeuZeit.Scheduling.TermDates
  alias NeuZeitWeb.ExceptionLive.FormComponent
  alias NeuZeitWeb.Nav

  @impl true
  def mount(%{"term_id" => term_id}, _session, socket) do
    term = Catalog.get_term!(term_id)

    {:ok,
     socket
     |> assign(:page_title, gettext("One-off changes"))
     |> assign(:term, term)
     |> assign(:terms, Catalog.list_terms())
     |> assign(:grid, NeuZeit.Config.grid!(term))
     |> assign(:sessions, Catalog.list_sessions(term_id))
     |> assign(:rooms, Catalog.list_rooms())
     |> assign(:teachers, Catalog.list_teachers())
     |> assign(:reverting, nil)
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = Nav.assign_return(socket, params)
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, params) do
    socket
    |> assign(:editing, FormComponent.new_exception(socket.assigns.term.id, params))
    |> assign(:form_params, params)
  end

  defp apply_action(socket, :edit, %{"id" => id} = params) do
    socket
    |> assign(:editing, Planning.get_schedule_exception!(id, socket.assigns.term.id))
    |> assign(:form_params, params)
  end

  defp apply_action(socket, :index, _params),
    do: socket |> assign(:editing, nil) |> assign(:form_params, %{})

  @impl true
  def handle_info({FormComponent, :saved, _exception}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, gettext("Change saved."))
     |> finish_edit()
     |> load()}
  end

  @impl true
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
    active_plan = Enum.find(Planning.list_plans(socket.assigns.term.id), &(&1.status == "active"))

    placements =
      case active_plan do
        nil -> %{}
        plan -> Map.new(Planning.get_plan!(plan.id).placements, &{&1.session_id, &1})
      end

    socket
    |> assign(:active_plan, active_plan)
    |> assign(:placements, placements)
    |> assign(
      :session_labels,
      FormComponent.session_labels(
        socket.assigns.sessions,
        socket.assigns.term.weeks_count,
        placements,
        socket.assigns.grid
      )
    )
    |> assign(:exceptions, Planning.list_schedule_exceptions(socket.assigns.term.id))
  end

  # The date the calendar shows the change on.
  defp shown_date(%{kind: kind, new_date: %Date{} = date}) when kind in ["move", "add"], do: date
  defp shown_date(exception), do: exception.occurrence_date

  defp calendar_link(assigns, exception) do
    date = shown_date(exception)
    week = assigns.term |> TermDates.week(date) |> max(1) |> min(assigns.term.weeks_count)

    params =
      %{
        "plan_id" => assigns.active_plan && assigns.active_plan.id,
        "week" => week,
        "occurrence" => "#{exception.session_id}:#{Date.to_iso8601(date)}"
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    ~p"/terms/#{assigns.term}/calendar?#{params}"
  end

  # Cancel and the close button go back to where the form was opened from.
  defp cancel_command(%{return_to: return_to}) when is_binary(return_to),
    do: JS.navigate(return_to)

  defp cancel_command(assigns), do: JS.patch(~p"/terms/#{assigns.term}/exceptions")

  defp change_action("cancel"), do: gettext("Cancel dated session")
  defp change_action("move"), do: gettext("Change date, time or format")
  defp change_action("substitute"), do: gettext("Replace teacher")
  defp change_action("add"), do: gettext("Add a dated session")
  defp change_action(_kind), do: gettext("New change")

  defp kind_label("cancel"), do: gettext("Cancelled")
  defp kind_label("move"), do: gettext("Moved")
  defp kind_label("substitute"), do: gettext("Teacher replaced")
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
      <.link :if={@return_to} navigate={@return_to} class="btn mb-4">{Nav.return_label(@return_to)}</.link>
      <.page_header title={gettext("One-off changes")}>
        <:actions>
          <.link patch={~p"/terms/#{@term}/exceptions/new"} class="btn btn-primary">
            <.icon name="hero-plus" class="size-4" /> {gettext("New change")}
          </.link>
        </:actions>
      </.page_header>

      <div class={["grid items-start gap-4", @editing && "lg:grid-cols-[minmax(0,1fr)_24rem]"]}>
        <div class="min-w-0">
          <.empty_state
            :if={@exceptions == []}
            title={gettext("No one-off changes")}
            message={
              gettext(
                "Cancel or move a dated session, add one or replace its teacher. Each change keeps its reason and author."
              )
            }
            icon="hero-calendar-days"
          >
            <:actions>
              <.link patch={~p"/terms/#{@term}/exceptions/new"} class="btn btn-primary">
                {gettext("New change")}
              </.link>
            </:actions>
          </.empty_state>

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
              {@session_labels[row.session_id]}
            </:col>
            <:col :let={row} label={gettext("Date")}><.date value={row.occurrence_date} /></:col>
            <:col :let={row} label={gettext("After the change")}>
              <.date :if={row.new_date} value={row.new_date} />
              <span :if={row.new_slot}>{NeuZeitWeb.Scheduling.SessionCard.time_range(
                @grid,
                row.new_slot,
                row.session.duration_slots
              )}</span>
              <span :if={row.new_room} class="text-base-content">, {row.new_room.name}</span>
              <span :if={row.kind in ["move", "add"]}>
                {delivery_mode_label(row.new_delivery_mode || row.session.delivery_mode)}
              </span>
            </:col>
            <:col :let={row} label={gettext("Substitute teacher")}>
              {row.new_teacher && row.new_teacher.name}
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
                navigate={calendar_link(assigns, row)}
                class="btn btn-ghost"
              >{gettext("Show in calendar")}</.link>
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
              else: change_action(@form_params["kind"] || "cancel")
          }
          on_close={cancel_command(assigns)}
        >
          <.live_component
            module={FormComponent}
            id={"exception-form-#{@editing.id || "new"}"}
            term={@term}
            grid={@grid}
            sessions={@sessions}
            rooms={@rooms}
            teachers={@teachers}
            placements={@placements}
            exception={@editing}
            params={@form_params}
            on_cancel={cancel_command(assigns)}
          />
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
end
