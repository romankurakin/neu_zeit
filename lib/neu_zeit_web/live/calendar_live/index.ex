defmodule NeuZeitWeb.CalendarLive.Index do
  @moduledoc """
  Shows a plan on calendar dates, excluding non-teaching days.

  Drafts can be reviewed before publication. One-off changes apply only
  to the active plan.
  """
  use NeuZeitWeb, :live_view

  alias NeuZeit.{Catalog, Planning}
  alias NeuZeitWeb.Nav

  @impl true
  def mount(%{"term_id" => term_id}, _session, socket) do
    term = Catalog.get_term!(term_id)
    plans = term_plans(term_id)

    {:ok,
     socket
     |> assign(:page_title, gettext("Calendar"))
     |> assign(:term, term)
     |> assign(:terms, Catalog.list_terms())
     |> assign(:grid, NeuZeit.Config.grid!())
     |> assign(:plans, plans)
     |> assign(:week, 1)
     |> assign(:scope, "all")
     |> assign(:room_options, Catalog.list_rooms())
     |> assign(:cohorts, Catalog.list_cohorts())
     |> assign(:teachers, Catalog.list_teachers())
     |> select_plan(default_plan(plans))}
  end

  defp term_plans(term_id), do: Planning.list_plans(term_id)

  defp default_plan([]), do: nil
  defp default_plan(plans), do: Enum.find(plans, &(&1.status == "active")) || hd(plans)

  @impl true
  def handle_event("select_week", %{"week" => week}, socket),
    do: {:noreply, push_patch(socket, to: calendar_path(socket.assigns, %{"week" => week}))}

  def handle_event("select_plan", %{"plan_id" => id}, socket),
    do: {:noreply, push_patch(socket, to: calendar_path(socket.assigns, %{"plan_id" => id}))}

  def handle_event("select_scope", %{"scope" => scope}, socket),
    do: {:noreply, push_patch(socket, to: calendar_path(socket.assigns, %{"scope" => scope}))}

  def handle_event("move_occurrence", params, socket) do
    if socket.assigns.plan && socket.assigns.plan.status == "active" do
      occurrence =
        Enum.find(socket.assigns.projection.occurrences, fn o ->
          o.session_id == params["session-id"] && Date.to_iso8601(o.date) == params["from"] &&
            (is_nil(params["exception-id"]) || params["exception-id"] == "" ||
               o.exception_id == params["exception-id"])
        end)

      if occurrence do
        {:noreply,
         push_navigate(socket, to: action_path(socket.assigns, occurrence, "move", params["to"]))}
      else
        {:noreply,
         Errors.put(
           socket,
           {:conflict, gettext("This dated session has changed. Reload the calendar.")}
         )}
      end
    else
      {:noreply,
       Errors.put(
         socket,
         {:conflict,
          gettext("One-off changes apply to the published timetable. Publish this plan first.")}
       )}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    plan =
      if params["plan_id"],
        do: Enum.find(socket.assigns.plans, &(&1.id == params["plan_id"])),
        else: socket.assigns.plan

    socket =
      if plan && (!socket.assigns.plan || plan.id != socket.assigns.plan.id),
        do: select_plan(socket, plan),
        else: socket

    week =
      case Integer.parse(params["week"] || "1") do
        {n, ""} -> min(max(1, n), socket.assigns.term.weeks_count)
        _ -> 1
      end

    {:noreply, socket |> assign(:week, week) |> assign(:scope, params["scope"] || "all")}
  end

  defp calendar_path(assigns, changes \\ %{}) do
    params =
      Map.merge(
        %{
          "plan_id" => assigns.plan && assigns.plan.id,
          "week" => assigns.week,
          "scope" => assigns.scope
        },
        changes
      )

    ~p"/terms/#{assigns.term}/calendar?#{params}"
  end

  defp action_path(assigns, occurrence, kind, new_date \\ nil) do
    if occurrence.exception_id do
      exception = Map.fetch!(assigns.exceptions, occurrence.exception_id)

      params = %{
        "return_to" => calendar_path(assigns),
        "new_date" => new_date,
        "kind" => if(exception.kind == "add", do: "add", else: kind)
      }

      ~p"/terms/#{assigns.term}/exceptions/#{exception.id}/edit?#{params}"
    else
      params = %{
        "kind" => kind,
        "session_id" => occurrence.session_id,
        "date" => Date.to_iso8601(occurrence.date),
        "new_date" => new_date || Date.to_iso8601(occurrence.date),
        "new_slot" => occurrence.slot,
        "new_room_id" => occurrence.room_id,
        "return_to" => calendar_path(assigns)
      }

      ~p"/terms/#{assigns.term}/exceptions/new?#{params}"
    end
  end

  defp select_plan(socket, nil),
    do:
      socket
      |> assign(:plan, nil)
      |> assign(:projection, nil)
      |> assign(:sessions, %{})
      |> assign(:rooms, %{})
      |> assign(:exceptions, %{})

  defp select_plan(socket, plan) do
    projection = Planning.project_plan(plan.id)

    # Occurrences contain IDs. Load room records for display, including rooms used
    # only by dated changes.
    sessions = Map.new(Catalog.list_sessions(plan.term_id), &{&1.id, &1})

    exceptions =
      if plan.status == "active",
        do:
          Planning.list_schedule_exceptions(plan.term_id) |> Enum.filter(&(&1.status == "active")),
        else: []

    cancelled =
      for e <- exceptions,
          e.kind == "cancel",
          p = Enum.find(projection.plan.placements, &(&1.session_id == e.session_id)),
          p != nil,
          do: %NeuZeit.Planning.Occurrence{
            session_id: e.session_id,
            date: e.occurrence_date,
            day: Date.day_of_week(e.occurrence_date),
            slot: p.slot,
            room_id: p.room_id,
            duration_slots: p.duration_slots,
            placement_id: p.id,
            exception_id: e.id,
            source: :cancel,
            cancelled?: true
          }

    projection = Map.update!(projection, :occurrences, &(&1 ++ cancelled))
    rooms = Map.new(Catalog.list_rooms(), &{&1.id, &1})

    socket
    |> assign(:plan, plan)
    |> assign(:projection, projection)
    |> assign(:sessions, sessions)
    |> assign(:rooms, rooms)
    |> assign(:exceptions, Map.new(exceptions, &{&1.id, &1}))
  end

  # Shaping

  defp week_dates(term, week, grid) do
    for day <- 0..(length(grid.days) - 1) do
      Date.add(term.starts_on, (week - 1) * 7 + day)
    end
  end

  defp occurrences_on(nil, _date, _scope, _sessions), do: []

  defp occurrences_on(projection, date, scope, sessions) do
    projection.occurrences
    |> Enum.filter(fn occurrence ->
      occurrence.date == date and
        (occurrence.room_id == scope or in_scope?(Map.get(sessions, occurrence.session_id), scope))
    end)
    |> Enum.sort_by(& &1.slot)
  end

  defp in_scope?(_session, "all"), do: true
  defp in_scope?(nil, _scope), do: false

  defp in_scope?(session, scope),
    do: Enum.any?(session.cohorts, &(&1.id == scope)) or session.teacher_id == scope

  # Find the week containing the first excluded date.
  defp holiday_week(term) do
    case term.excluded_dates do
      [] -> nil
      [first | _] -> div(Date.diff(first, term.starts_on), 7) + 1
    end
  end

  defp busiest_week(nil, _term), do: nil

  defp busiest_week(projection, term) do
    projection.occurrences
    |> Enum.frequencies_by(&(div(Date.diff(&1.date, term.starts_on), 7) + 1))
    |> Enum.max_by(fn {_week, count} -> count end, fn -> {1, 0} end)
    |> elem(0)
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:dates, week_dates(assigns.term, assigns.week, assigns.grid))
      |> assign(:excluded, MapSet.new(assigns.term.excluded_dates))
      |> assign(:busiest, busiest_week(assigns.projection, assigns.term))
      |> assign(:holiday, holiday_week(assigns.term))

    ~H"""
    <Layouts.app
      flash={@flash}
      nav={Nav.sections(@term)}
      current_path={~p"/terms/#{@term}/calendar"}
      terms={@terms}
      current_term={@term}
      page_path={calendar_path(assigns)}
    >
      <.page_header title={gettext("Calendar by date")} />

      <.empty_state
        :if={is_nil(@plan)}
        title={gettext("No timetable yet")}
        message={gettext("Create a plan and schedule sessions to see calendar dates.")}
        icon="hero-calendar-days"
      >
        <:actions>
          <.link navigate={~p"/terms/#{@term}/plans"} class="btn btn-primary">{gettext("Plans")}</.link>
        </:actions>
      </.empty_state>

      <div :if={@plan}>
        <.toolbar>
          <form id="calendar-plan-filter" phx-change="select_plan">
            <label for="calendar-plan" class="sr-only">{gettext("Plan")}</label>
            <select id="calendar-plan" name="plan_id" class="select select-bordered">
              <option :for={plan <- @plans} value={plan.id} selected={plan.id == @plan.id}>
                {plan.name}
              </option>
            </select>
          </form>

          <form id="calendar-resource-filter" phx-change="select_scope">
            <label for="calendar-resource" class="sr-only">{gettext("Resource")}</label>
            <select id="calendar-resource" name="scope" class="select select-bordered">
              <option value="all">{gettext("Everything")}</option>
              <optgroup label={gettext("Groups")}>
                <option :for={cohort <- @cohorts} value={cohort.id} selected={@scope == cohort.id}>
                  {cohort.name}
                </option>
              </optgroup>
              <optgroup label={gettext("Teachers")}>
                <option :for={teacher <- @teachers} value={teacher.id} selected={@scope == teacher.id}>
                  {teacher.name}
                </option>
              </optgroup>
              <optgroup label={gettext("Rooms")}>
                <option :for={room <- @room_options} value={room.id} selected={@scope == room.id}>
                  {room.name}
                </option>
              </optgroup>
            </select>
          </form>

          <.status_indicator status={@plan.status} />

          <:actions>
            <.week_picker
              weeks_count={@term.weeks_count}
              current={@week}
              busiest={@busiest}
              holiday={@holiday}
              event="select_week"
            />
          </:actions>
        </.toolbar>

        <p :if={@plan.status != "active"} class="mb-4 type-detail text-base-content">
          {gettext("One-off changes are shown only for the published plan.")}
        </p>

        <div class="flex flex-wrap gap-2 mb-4">
          <.link navigate={~p"/terms/#{@term}/plans/#{@plan}?week=#{@week}"} class="btn">{gettext(
            "Semester template"
          )}</.link>
          <.link
            :if={@plan.status == "active"}
            navigate={~p"/terms/#{@term}/exceptions/new?kind=add&return_to=#{calendar_path(assigns)}"}
            class="btn"
          >{gettext("Add a dated session")}</.link>
        </div>
        <div
          id="calendar-grid"
          phx-hook=".CalendarDrag"
          data-readonly={to_string(@plan.status != "active")}
          tabindex="0"
          role="region"
          aria-label={gettext("Timetable. Scroll horizontally to see all days.")}
          class="grid grid-flow-col auto-cols-[minmax(18rem,1fr)] gap-2 overflow-x-auto pb-2"
        >
          <div
            :for={{date, index} <- Enum.with_index(@dates)}
            id={"calendar-day-#{Date.to_iso8601(date)}"}
            data-dropzone="day"
            data-date={Date.to_iso8601(date)}
            data-excluded={to_string(MapSet.member?(@excluded, date))}
            class={[
              "rounded-box border p-2",
              if(MapSet.member?(@excluded, date),
                do: "border-error/40 bg-error/5",
                else: "border-base-300 bg-base-100"
              )
            ]}
          >
            <div class="mb-2 flex items-baseline justify-between gap-2 border-b border-base-300 pb-1">
              <span class="type-detail font-semibold">{day_label(Enum.at(@grid.days, index))}</span>
              <span class="tabular-nums type-detail text-base-content">
                <.date value={date} format="day_month" />
              </span>
            </div>

            <p :if={MapSet.member?(@excluded, date)} class="py-2 text-center type-detail text-error">
              {gettext("Non-teaching date")}
            </p>

            <div
              data-occurrences
              data-date={Date.to_iso8601(date)}
              data-excluded={to_string(MapSet.member?(@excluded, date))}
              class="flex flex-col gap-1 min-h-12"
            >
              <p
                :if={occurrences_on(@projection, date, @scope, @sessions) == []}
                class="py-2 text-center type-detail text-base-content"
              >
                {gettext("Nothing scheduled")}
              </p>

              <div
                :for={occurrence <- occurrences_on(@projection, date, @scope, @sessions)}
                data-session-id={occurrence.session_id}
                data-date={Date.to_iso8601(date)}
                data-exception-id={occurrence.exception_id}
                data-cancelled={to_string(occurrence.cancelled?)}
                class={[
                  "rounded-field border px-2 py-1 type-detail",
                  if(occurrence.source in [:move, :add, :cancel],
                    do: "border-info/50 bg-info/10",
                    else: "border-base-300"
                  )
                ]}
              >
                <% session = Map.get(@sessions, occurrence.session_id) %>
                <div class="flex flex-wrap items-baseline justify-between gap-1">
                  <span class="font-semibold">
                    {session && session.course_component.course.code}
                  </span>
                  <span class="tabular-nums text-base-content">
                    {NeuZeitWeb.Scheduling.SessionCard.time_range(
                      @grid,
                      occurrence.slot,
                      occurrence.duration_slots || 1
                    )}
                  </span>
                </div>
                <div class="break-words font-semibold">
                  {session && session.course_component.course.title}
                </div>
                <div class="break-words">{session && session.teacher.name}</div>
                <span
                  :if={occurrence.source != :template}
                  class="badge badge-md badge-outline h-auto my-1"
                >
                  {case occurrence.source do
                    :move -> gettext("Moved")
                    :add -> gettext("Added")
                    :cancel -> gettext("Cancelled")
                  end}
                </span>
                <p
                  :if={
                    occurrence.source in [:move, :cancel] && occurrence.exception_id &&
                      @exceptions[occurrence.exception_id]
                  }
                  class="type-detail my-1"
                >
                  {gettext("Original date: %{date}",
                    date: @exceptions[occurrence.exception_id].occurrence_date
                  )}
                </p>
                <div class="flex flex-wrap items-center gap-1">
                  <span
                    :for={cohort <- (session && session.cohorts) || []}
                    class="badge badge-ghost badge-md"
                  >
                    {cohort.name}
                  </span>
                  <span class="ml-auto text-base-content">
                    {room_name(@rooms, occurrence.room_id)}
                  </span>
                </div>
                <div :if={@plan.status == "active"} class="flex flex-wrap gap-1 mt-2">
                  <.link
                    navigate={
                      if occurrence.exception_id,
                        do:
                          ~p"/terms/#{@term}/exceptions/#{occurrence.exception_id}/edit?return_to=#{calendar_path(assigns)}",
                        else: action_path(assigns, occurrence, "move")
                    }
                    class="btn"
                  >{if occurrence.exception_id,
                    do: gettext("Edit change"),
                    else: gettext("Move dated session")}</.link>
                  <.link
                    :if={is_nil(occurrence.exception_id)}
                    navigate={action_path(assigns, occurrence, "cancel")}
                    class="btn"
                  >{gettext("Cancel dated session")}</.link>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".CalendarDrag">
        import {
          acknowledgePatch,
          defineHook,
          dragAnimation,
          htmlElements,
          restoreDraggedItem,
        } from "@/js/hook-dom.js";
        import Sortable from "sortablejs";

        export default defineHook({
          destroyed() {
            this.teardown();
          },

          mounted() {
            this.setup();
          },

          /** @param {import("sortablejs").SortableEvent} event */
          onDrop(event) {
            const from = event.item.dataset.date;
            const to = event.to.dataset.date;
            restoreDraggedItem(event);
            if (typeof to === "string" && to !== from && event.to.dataset.excluded !== "true") {
              this.pushEvent(
                "move_occurrence",
                {
                  "exception-id": event.item.dataset.exceptionId,
                  from,
                  "session-id": event.item.dataset.sessionId,
                  to,
                },
                acknowledgePatch,
              );
            }
          },

          setup() {
            this.teardown();
            if (this.el.dataset.readonly !== "true") {
              this.sorters = htmlElements(this.el, '[data-dropzone="day"] [data-occurrences]').map((list) =>
                Sortable.create(list, {
                  animation: dragAnimation(),
                  draggable: '[data-session-id][data-cancelled="false"]',
                  filter: "a,button",
                  forceFallback: true,
                  ghostClass: "opacity-40",
                  group: "calendar",
                  onEnd: (event) => {
                    this.onDrop(event);
                  },
                  preventOnFilter: false,
                }),
              );
            }
          },

          /** @type {Sortable[]} */
          sorters: [],

          teardown() {
            for (const sorter of this.sorters) {
              sorter.destroy();
            }
            this.sorters = [];
          },

          updated() {
            this.setup();
          },
        });
      </script>
    </Layouts.app>
    """
  end

  defp room_name(rooms, room_id) do
    case Map.get(rooms, room_id) do
      nil -> ""
      room -> room.name
    end
  end
end
