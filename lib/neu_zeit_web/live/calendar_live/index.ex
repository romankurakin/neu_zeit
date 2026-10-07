defmodule NeuZeitWeb.CalendarLive.Index do
  @moduledoc """
  Shows a plan on calendar dates, excluding non-teaching days.

  Drafts can be reviewed before publication. One-off changes apply only
  to the active plan. Selecting a dated session opens a panel with its
  details and the changes it allows.
  """
  use NeuZeitWeb, :live_view

  alias NeuZeit.{Catalog, Planning}
  alias NeuZeit.Scheduling.TermDates
  alias NeuZeitWeb.ExceptionLive.FormComponent
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
     |> assign(:grid, NeuZeit.Config.grid!(term))
     |> assign(:plans, plans)
     |> assign(:week, default_week(term))
     |> assign(:scope, "all")
     |> assign(:selection, nil)
     |> assign(:change, nil)
     |> assign(:reverting, nil)
     |> assign(:room_options, Catalog.list_rooms())
     |> assign(:cohorts, Catalog.list_cohorts())
     |> assign(:teachers, Catalog.list_teachers())
     |> select_plan(default_plan(plans))}
  end

  defp term_plans(term_id), do: Planning.list_plans(term_id)

  defp default_plan([]), do: nil
  defp default_plan(plans), do: Enum.find(plans, &(&1.status == "active")) || hd(plans)

  # The week with today's date in the institution's time zone. After the term,
  # the last week. Before it, the first.
  defp default_week(term) do
    today =
      case DateTime.now(NeuZeit.Settings.snapshot().timezone) do
        {:ok, now} -> DateTime.to_date(now)
        {:error, _reason} -> Date.utc_today()
      end

    cond do
      TermDates.within?(term, today) -> clamp_week(term, TermDates.week(term, today))
      term.ends_on && Date.after?(today, term.ends_on) -> term.weeks_count
      true -> 1
    end
  end

  defp clamp_week(term, week), do: week |> max(1) |> min(term.weeks_count)

  @impl true
  def handle_event("select_week", %{"week" => week}, socket),
    do: {:noreply, push_patch(socket, to: calendar_path(socket.assigns, %{"week" => week}))}

  def handle_event("select_plan", %{"plan_id" => id}, socket),
    do: {:noreply, push_patch(socket, to: calendar_path(socket.assigns, %{"plan_id" => id}))}

  def handle_event("select_scope", %{"scope" => scope}, socket),
    do: {:noreply, push_patch(socket, to: calendar_path(socket.assigns, %{"scope" => scope}))}

  def handle_event("select_occurrence", %{"session-id" => session_id, "date" => date}, socket),
    do:
      {:noreply,
       push_patch(socket,
         to: calendar_path(socket.assigns, %{"occurrence" => "#{session_id}:#{date}"})
       )}

  def handle_event("clear_selection", _params, socket),
    do: {:noreply, push_patch(socket, to: calendar_path(socket.assigns, %{"occurrence" => nil}))}

  def handle_event("open_change", %{"kind" => "add"}, socket) do
    with :ok <- require_active_plan(socket) do
      {:noreply,
       assign(socket, :change, %{
         title: gettext("Add a dated session"),
         exception: FormComponent.new_exception(socket.assigns.term.id, %{"kind" => "add"}),
         params: %{"kind" => "add"}
       })}
    end
  end

  def handle_event("open_change", %{"kind" => kind}, socket) do
    with :ok <- require_active_plan(socket),
         {:ok, occurrence} <- selected_occurrence(socket) do
      {:noreply, assign(socket, :change, change_for(socket.assigns, occurrence, kind, nil))}
    end
  end

  def handle_event("close_change", _params, socket),
    do: {:noreply, assign(socket, :change, nil)}

  def handle_event("move_occurrence", params, socket) do
    with :ok <- require_active_plan(socket) do
      occurrence =
        Enum.find(socket.assigns.projection.occurrences, fn o ->
          o.session_id == params["session-id"] && Date.to_iso8601(o.date) == params["from"] &&
            (is_nil(params["exception-id"]) || params["exception-id"] == "" ||
               o.exception_id == params["exception-id"])
        end)

      if occurrence do
        {:noreply,
         assign(socket, :change, change_for(socket.assigns, occurrence, "move", params["to"]))}
      else
        {:noreply,
         Errors.put(
           socket,
           {:conflict, gettext("This dated session has changed. Reload the calendar.")}
         )}
      end
    end
  end

  def handle_event("revert_prompt", _params, socket) do
    with {:ok, occurrence} <- selected_occurrence(socket),
         %{} = exception <- Map.get(socket.assigns.exceptions, occurrence.exception_id) do
      {:noreply, assign(socket, :reverting, exception)}
    else
      _missing -> {:noreply, socket}
    end
  end

  def handle_event("revert_cancel", _params, socket),
    do: {:noreply, assign(socket, :reverting, nil)}

  def handle_event("revert_confirm", _params, socket) do
    exception = socket.assigns.reverting

    case Planning.update_schedule_exception(exception, %{"status" => "reverted"}) do
      {:ok, _exception} ->
        {:noreply,
         socket
         |> assign(:reverting, nil)
         |> put_flash(:info, gettext("Change reverted. Its history is kept."))
         |> select_plan(socket.assigns.plan)
         |> push_patch(
           to: path_showing(socket.assigns, exception.session_id, exception.occurrence_date)
         )}

      {:error, reason} ->
        {:noreply, socket |> assign(:reverting, nil) |> Errors.put(reason)}
    end
  end

  @impl true
  def handle_info({FormComponent, :saved, exception}, socket) do
    date =
      if exception.kind in ["move", "add"] && exception.new_date,
        do: exception.new_date,
        else: exception.occurrence_date

    {:noreply,
     socket
     |> assign(:change, nil)
     |> put_flash(:info, gettext("Change saved."))
     |> select_plan(socket.assigns.plan)
     |> push_patch(to: path_showing(socket.assigns, exception.session_id, date))}
  end

  defp require_active_plan(socket) do
    if socket.assigns.plan && socket.assigns.plan.status == "active" do
      :ok
    else
      {:noreply,
       Errors.put(
         socket,
         {:conflict,
          gettext("One-off changes apply only to the active plan. Publish this plan first.")}
       )}
    end
  end

  defp selected_occurrence(socket) do
    case find_occurrence(socket.assigns.projection, socket.assigns.selection) do
      nil -> {:noreply, socket}
      occurrence -> {:ok, occurrence}
    end
  end

  # The dialog state for a change to an occurrence. A dragged card gives the new date.
  defp change_for(assigns, occurrence, kind, new_date) do
    position = %{
      "new_date" => new_date || Date.to_iso8601(occurrence.date),
      "new_slot" => to_string(occurrence.slot),
      "new_room_id" => occurrence.room_id,
      "new_delivery_mode" => occurrence.delivery_mode && to_string(occurrence.delivery_mode)
    }

    cond do
      occurrence.exception_id && kind == "edit" ->
        %{
          title: gettext("Edit change"),
          exception: Planning.get_schedule_exception!(occurrence.exception_id, assigns.term.id),
          params: %{}
        }

      occurrence.exception_id ->
        exception = Planning.get_schedule_exception!(occurrence.exception_id, assigns.term.id)
        kind = if exception.kind == "add", do: "add", else: kind

        %{
          title: gettext("Edit change"),
          exception: exception,
          params: Map.put(position, "kind", kind)
        }

      true ->
        params =
          Map.merge(position, %{
            "kind" => kind,
            "session_id" => occurrence.session_id,
            "date" => Date.to_iso8601(occurrence.date)
          })

        %{
          title: change_title(kind),
          exception: FormComponent.new_exception(assigns.term.id, params),
          params: params
        }
    end
  end

  defp change_title("cancel"), do: gettext("Cancel dated session")
  defp change_title("move"), do: gettext("Change date, time or format")
  defp change_title("substitute"), do: gettext("Replace teacher")
  defp change_title(_kind), do: gettext("Edit change")

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
      case Integer.parse(params["week"] || "") do
        {n, ""} -> clamp_week(socket.assigns.term, n)
        _ -> default_week(socket.assigns.term)
      end

    {:noreply,
     socket
     |> assign(:week, week)
     |> assign(:scope, params["scope"] || "all")
     |> assign(:selection, parse_selection(params["occurrence"]))}
  end

  defp parse_selection(value) when is_binary(value) do
    with [session_id, date] <- String.split(value, ":", parts: 2),
         {:ok, date} <- Date.from_iso8601(date) do
      {session_id, date}
    else
      _invalid -> nil
    end
  end

  defp parse_selection(_value), do: nil

  defp find_occurrence(nil, _selection), do: nil
  defp find_occurrence(_projection, nil), do: nil

  defp find_occurrence(projection, {session_id, date}) do
    projection.occurrences
    |> Enum.filter(&(&1.session_id == session_id && &1.date == date))
    |> Enum.min_by(&(&1.cancelled? == true), fn -> nil end)
  end

  defp calendar_path(assigns, changes \\ %{}) do
    params =
      %{
        "plan_id" => assigns.plan && assigns.plan.id,
        "week" => assigns.week,
        "scope" => assigns.scope,
        "occurrence" =>
          case assigns.selection do
            {session_id, date} -> "#{session_id}:#{Date.to_iso8601(date)}"
            nil -> nil
          end
      }
      |> Map.merge(changes)
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    ~p"/terms/#{assigns.term}/calendar?#{params}"
  end

  # The calendar path that shows the week of a date with that occurrence selected.
  defp path_showing(assigns, session_id, date) do
    calendar_path(assigns, %{
      "week" => clamp_week(assigns.term, TermDates.week(assigns.term, date)),
      "occurrence" => "#{session_id}:#{Date.to_iso8601(date)}"
    })
  end

  defp select_plan(socket, nil),
    do:
      socket
      |> assign(:plan, nil)
      |> assign(:projection, nil)
      |> assign(:sessions, %{})
      |> assign(:session_list, [])
      |> assign(:rooms, %{})
      |> assign(:exceptions, %{})

  defp select_plan(socket, plan) do
    projection = Planning.project_plan(plan.id)

    # Occurrences contain IDs. Load room records for display, including rooms used
    # only by dated changes.
    session_list = Catalog.list_sessions(plan.term_id)
    sessions = Map.new(session_list, &{&1.id, &1})

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
            delivery_mode:
              Map.get(Map.get(sessions, p.session_id, %{}), :delivery_mode, :in_person),
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
    |> assign(:session_list, session_list)
    |> assign(:rooms, rooms)
    |> assign(:exceptions, Map.new(exceptions, &{&1.id, &1}))
  end

  # Shaping

  defp week_dates(term, week, grid) do
    for day <- 0..(length(grid.days) - 1) do
      TermDates.date(term, week, day + 1)
    end
  end

  defp occurrences_on(nil, _date, _scope, _sessions), do: []

  defp occurrences_on(projection, date, scope, sessions) do
    projection.occurrences
    |> Enum.filter(fn occurrence ->
      occurrence.date == date and
        (occurrence.room_id == scope or
           in_scope?(Map.get(sessions, occurrence.session_id), occurrence, scope))
    end)
    |> Enum.sort_by(& &1.slot)
  end

  defp in_scope?(_session, _occurrence, "all"), do: true
  defp in_scope?(nil, _occurrence, _scope), do: false

  defp in_scope?(session, occurrence, scope),
    do:
      Enum.any?(session.cohorts, &(&1.id == scope)) or
        (occurrence.teacher_id || session.teacher_id) == scope

  # Find the week containing the first excluded date.
  defp holiday_week(term) do
    case term.excluded_dates do
      [] -> nil
      [first | _] -> TermDates.week(term, first)
    end
  end

  defp busiest_week(nil, _term), do: nil

  defp busiest_week(projection, term) do
    projection.occurrences
    |> Enum.frequencies_by(&TermDates.week(term, &1.date))
    |> Enum.max_by(fn {_week, count} -> count end, fn -> {1, 0} end)
    |> elem(0)
  end

  defp placement_weeks(projection, session) do
    case Enum.find(projection.plan.placements, &(&1.session_id == session.id)) do
      nil -> session.week_mask
      placement -> placement.week_mask
    end
  end

  # The form needs the active placements by session id for the session labels.
  defp placements_by_session(nil), do: %{}

  defp placements_by_session(projection),
    do: Map.new(projection.plan.placements, &{&1.session_id, &1})

  @impl true
  def render(assigns) do
    selected = find_occurrence(assigns.projection, assigns.selection)

    assigns =
      assigns
      |> assign(:dates, week_dates(assigns.term, assigns.week, assigns.grid))
      |> assign(:excluded, MapSet.new(assigns.term.excluded_dates))
      |> assign(:busiest, busiest_week(assigns.projection, assigns.term))
      |> assign(:holiday, holiday_week(assigns.term))
      |> assign(:selected, selected)
      |> assign(:selected_session, selected && Map.get(assigns.sessions, selected.session_id))

    ~H"""
    <Layouts.app
      flash={@flash}
      nav={Nav.sections(@term)}
      current_path={~p"/terms/#{@term}/calendar"}
      terms={@terms}
      current_term={@term}
      page_path={calendar_path(assigns)}
    >
      <.page_header
        title={gettext("Calendar")}
        subtitle={gettext("Times in %{timezone}", timezone: NeuZeit.Settings.snapshot().timezone)}
      />

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
              term={@term}
              event="select_week"
            />
          </:actions>
        </.toolbar>

        <p :if={@plan.status != "active"} class="mb-4 type-detail text-base-content">
          {gettext("One-off changes are shown only for the active plan.")}
        </p>

        <div class="flex flex-wrap gap-2 mb-4">
          <.link navigate={~p"/terms/#{@term}/plans/#{@plan}?week=#{@week}"} class="btn">{gettext(
            "Semester template"
          )}</.link>
          <button
            :if={@plan.status == "active"}
            type="button"
            class="btn"
            phx-click="open_change"
            phx-value-kind="add"
          >{gettext("Add a dated session")}</button>
        </div>

        <div class={["grid items-start gap-4", @selected && "lg:grid-cols-[minmax(0,1fr)_20rem]"]}>
          <div
            id="calendar-grid"
            phx-hook=".CalendarDrag"
            data-readonly={to_string(@plan.status != "active")}
            tabindex="0"
            role="region"
            aria-label={gettext("Timetable. Scroll horizontally to see all days.")}
            class="min-w-0 grid grid-flow-col auto-cols-[minmax(18rem,1fr)] gap-2 overflow-x-auto pb-2"
          >
            <div
              :for={{date, index} <- Enum.with_index(@dates)}
              id={"calendar-day-#{Date.to_iso8601(date)}"}
              data-dropzone="day"
              data-date={Date.to_iso8601(date)}
              data-excluded={
                to_string(MapSet.member?(@excluded, date) or not TermDates.within?(@term, date))
              }
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

              <p :if={!TermDates.within?(@term, date)} class="py-2 text-center type-detail">
                {gettext("Outside term")}
              </p>

              <p :if={MapSet.member?(@excluded, date)} class="py-2 text-center type-detail text-error">
                {gettext("Non-teaching date")}
              </p>

              <div
                data-occurrences
                data-date={Date.to_iso8601(date)}
                data-excluded={
                  to_string(MapSet.member?(@excluded, date) or not TermDates.within?(@term, date))
                }
                class="flex flex-col gap-1 min-h-12"
              >
                <p
                  :if={
                    TermDates.within?(@term, date) &&
                      occurrences_on(@projection, date, @scope, @sessions) == []
                  }
                  class="py-2 text-center type-detail text-base-content"
                >
                  {gettext("Nothing scheduled")}
                </p>

                <button
                  :for={occurrence <- occurrences_on(@projection, date, @scope, @sessions)}
                  type="button"
                  data-session-id={occurrence.session_id}
                  data-date={Date.to_iso8601(date)}
                  data-exception-id={occurrence.exception_id}
                  data-cancelled={to_string(occurrence.cancelled?)}
                  phx-click={JS.push_focus() |> JS.push("select_occurrence")}
                  phx-value-session-id={occurrence.session_id}
                  phx-value-date={Date.to_iso8601(date)}
                  aria-pressed={
                    to_string(
                      !!(@selected && @selected.session_id == occurrence.session_id &&
                           @selected.date == date && @selected.cancelled? == occurrence.cancelled?)
                    )
                  }
                  class={[
                    "block w-full rounded-field border px-2 py-1 text-left type-detail",
                    "aria-pressed:border-primary aria-pressed:ring-1 aria-pressed:ring-primary",
                    if(occurrence.source in [:move, :add, :cancel, :substitute],
                      do: "border-info/50 bg-info/10",
                      else: "border-base-300"
                    )
                  ]}
                >
                  <% session = Map.get(@sessions, occurrence.session_id) %>
                  <span class="flex flex-wrap items-baseline justify-between gap-1">
                    <span class="font-semibold">
                      {session && course_title(session.course_component.course)}
                    </span>
                    <span class="tabular-nums text-base-content">
                      {NeuZeitWeb.Scheduling.SessionCard.time_range(
                        @grid,
                        occurrence.slot,
                        occurrence.duration_slots || 1
                      )}
                    </span>
                  </span>
                  <span class="block break-words">{teacher_name(@teachers, occurrence, session)}</span>
                  <span
                    :if={occurrence.source != :template}
                    class="badge badge-md badge-outline h-auto my-1"
                  >
                    {source_label(occurrence.source)}
                  </span>
                  <span
                    :if={
                      occurrence.source == :move && occurrence.exception_id &&
                        @exceptions[occurrence.exception_id]
                    }
                    class="block type-detail my-1"
                  >
                    {gettext("Original date")}:
                    <.date value={@exceptions[occurrence.exception_id].occurrence_date} />
                  </span>
                  <span class="flex flex-wrap items-center gap-1">
                    <span
                      :for={cohort <- (session && session.cohorts) || []}
                      class="badge badge-ghost badge-md"
                    >
                      {cohort.name}
                    </span>
                    <span class="ml-auto text-base-content">
                      {room_name(@rooms, occurrence.room_id)}
                    </span>
                  </span>
                </button>
              </div>
            </div>
          </div>

          <div
            :if={@selected}
            id="occurrence-panel"
            phx-mounted={JS.focus_first(to: "#occurrence-panel")}
            phx-remove={JS.pop_focus()}
            class="min-w-0 order-first lg:order-last lg:sticky lg:top-20 lg:max-h-[calc(100dvh-6rem)] lg:overflow-y-auto"
          >
            <.details_panel
              title={
                (@selected_session && course_title(@selected_session.course_component.course)) ||
                  gettext("Dated session")
              }
              subtitle={@selected_session && component_kind_label(@selected_session.course_component)}
              on_close="clear_selection"
            >
              <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 type-detail">
                <dt class="text-base-content">{gettext("Teacher")}</dt>
                <dd>{teacher_name(@teachers, @selected, @selected_session)}</dd>
                <dt class="text-base-content">{gettext("Groups")}</dt>
                <dd>
                  {Enum.map_join(
                    (@selected_session && @selected_session.cohorts) || [],
                    ", ",
                    & &1.name
                  )}
                </dd>
                <dt class="text-base-content">{gettext("Time")}</dt>
                <dd class="tabular-nums">
                  {day_label(Enum.at(@grid.days, @selected.day - 1))}
                  <.date value={@selected.date} format="day_month" />, {NeuZeitWeb.Scheduling.SessionCard.time_range(
                    @grid,
                    @selected.slot,
                    @selected.duration_slots || 1
                  )}
                </dd>
                <dt class="text-base-content">{gettext("Room")}</dt>
                <dd>{room_name(@rooms, @selected.room_id)}</dd>
                <dt class="text-base-content">{gettext("Delivery format")}</dt>
                <dd>{delivery_mode_label(@selected.delivery_mode)}</dd>
                <dt :if={@selected_session} class="text-base-content">{gettext("Teaching weeks")}</dt>
                <dd :if={@selected_session}>
                  {weeks_label(placement_weeks(@projection, @selected_session), @term.weeks_count)}
                </dd>
              </dl>

              <section
                :if={@selected.exception_id && @exceptions[@selected.exception_id]}
                id="selected-change"
                class="border-t border-base-300 pt-4"
              >
                <h3 class="type-heading">{gettext("One-off change")}</h3>
                <dl class="mt-2 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 type-detail">
                  <dt class="text-base-content">{gettext("Change")}</dt>
                  <dd>{source_label(@selected.source)}</dd>
                  <dt :if={@selected.source == :move} class="text-base-content">
                    {gettext("Original date")}
                  </dt>
                  <dd :if={@selected.source == :move}>
                    <.date value={@exceptions[@selected.exception_id].occurrence_date} />
                  </dd>
                  <dt class="text-base-content">{gettext("Reason")}</dt>
                  <dd>{@exceptions[@selected.exception_id].reason}</dd>
                  <dt class="text-base-content">{gettext("Author")}</dt>
                  <dd>{@exceptions[@selected.exception_id].created_by}</dd>
                </dl>
              </section>

              <p :if={@plan.status != "active"} class="type-detail">
                {gettext("One-off changes apply only to the active plan.")}
              </p>

              <:actions :if={@plan.status == "active"}>
                <button
                  :if={is_nil(@selected.exception_id)}
                  type="button"
                  class="btn"
                  phx-click="open_change"
                  phx-value-kind="move"
                >{gettext("Change date, time or format")}</button>
                <button
                  :if={is_nil(@selected.exception_id)}
                  type="button"
                  class="btn"
                  phx-click="open_change"
                  phx-value-kind="substitute"
                >{gettext("Replace teacher")}</button>
                <button
                  :if={is_nil(@selected.exception_id)}
                  type="button"
                  class="btn"
                  phx-click="open_change"
                  phx-value-kind="cancel"
                >{gettext("Cancel dated session")}</button>
                <button
                  :if={@selected.exception_id}
                  type="button"
                  class="btn"
                  phx-click="open_change"
                  phx-value-kind="edit"
                >{gettext("Edit change")}</button>
                <button
                  :if={@selected.exception_id}
                  type="button"
                  class="btn"
                  phx-click="revert_prompt"
                >{gettext("Revert change")}</button>
              </:actions>
            </.details_panel>
          </div>
        </div>
      </div>

      <.dialog
        :if={@change}
        id="change-dialog"
        title={@change.title}
        on_cancel="close_change"
        class="max-w-2xl"
      >
        <.live_component
          module={FormComponent}
          id="change-form"
          term={@term}
          grid={@grid}
          sessions={@session_list}
          rooms={Map.values(@rooms)}
          teachers={@teachers}
          placements={placements_by_session(@projection)}
          exception={@change.exception}
          params={@change.params}
          on_cancel="close_change"
        />
      </.dialog>

      <.alert_dialog
        :if={@reverting}
        title={gettext("Revert this change?")}
        message={gettext("The change will no longer apply. Its record will remain in the history.")}
        confirm_label={gettext("Revert change")}
        on_confirm="revert_confirm"
        on_cancel="revert_cancel"
        variant="primary"
      />

      <script :type={Phoenix.LiveView.ColocatedHook} name=".CalendarDrag">
        import {
          acknowledgePatch,
          defineHook,
          dragAnimation,
          htmlElements,
          restoreDraggedItem,
        } from "@/js/hook-dom";
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
                  forceFallback: true,
                  ghostClass: "opacity-40",
                  group: "calendar",
                  onEnd: (event) => {
                    this.onDrop(event);
                  },
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

  defp source_label(:move), do: gettext("Moved")
  defp source_label(:add), do: gettext("Added")
  defp source_label(:cancel), do: gettext("Cancelled")
  defp source_label(:substitute), do: gettext("Teacher replaced")
  defp source_label(_source), do: ""

  defp teacher_name(teachers, occurrence, session) do
    teacher_id = occurrence.teacher_id || (session && session.teacher_id)

    case Enum.find(teachers, &(&1.id == teacher_id)) do
      nil -> ""
      teacher -> teacher.name
    end
  end

  defp room_name(_rooms, nil), do: gettext("Online")

  defp room_name(rooms, room_id) do
    case Map.get(rooms, room_id) do
      nil -> ""
      room -> room.name
    end
  end
end
