defmodule NeuZeitWeb.SessionLive.Index do
  @moduledoc """
  Edits the sessions required for a term.

  Each session has a teacher, attending groups, weeks and duration.
  A shared lecture is one session with all attending groups.
  """
  use NeuZeitWeb, :live_view

  alias NeuZeit.{Catalog, Planning}
  alias NeuZeit.Catalog.Session
  alias NeuZeitWeb.Nav

  @empty_filters %{
    "course_id" => "all",
    "teacher_id" => "all",
    "cohort_id" => "all",
    "slot_profile_id" => "all",
    "without_profile" => "false",
    "unplaced_in_plan" => "all"
  }

  @impl true
  def mount(%{"term_id" => term_id}, _session, socket) do
    term = Catalog.get_term!(term_id)

    {:ok,
     socket
     |> assign(:page_title, gettext("Sessions"))
     |> assign(:term, term)
     |> assign(:terms, Catalog.list_terms())
     |> assign(:page, 1)
     |> assign(:filters, @empty_filters)
     |> assign(:courses, Catalog.list_courses())
     |> assign(:teachers, Catalog.list_teachers())
     |> assign(:cohorts, Catalog.list_cohorts())
     |> assign(:plans, Planning.list_plans(term_id))
     |> assign(:profiles, Catalog.list_slot_profiles(term_id))
     |> assign(:components, component_options())
     |> assign(:editing, nil)
     |> assign(:deleting, nil)
     |> assign(:count, 0)
     |> assign(:pages, 1)
     |> stream(:sessions, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    base =
      if socket.assigns.live_action == :index, do: @empty_filters, else: socket.assigns.filters

    filters = Map.merge(base, Map.take(params, Map.keys(@empty_filters)))

    filters =
      Map.new(filters, fn {key, value} ->
        valid =
          key == "without_profile" or value == "all" or match?({:ok, _}, Ecto.UUID.cast(value))

        {key, if(valid, do: value, else: @empty_filters[key])}
      end)

    page =
      case Integer.parse(params["page"] || "1") do
        {n, ""} -> max(n, 1)
        _ -> 1
      end

    socket =
      socket
      |> Nav.assign_return(params)
      |> assign(:filters, filters)
      |> assign(:page, page)
      |> load_sessions()

    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    session = %Session{
      term_id: socket.assigns.term.id,
      week_mask: all_weeks(socket),
      duration_slots: 1
    }

    open_form(socket, session, [])
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    session = Catalog.get_session!(id, socket.assigns.term.id)
    open_form(socket, session, Enum.map(session.cohorts, & &1.id))
  end

  defp apply_action(socket, :index, _params),
    do: socket |> assign(:editing, nil) |> assign(:form, nil)

  defp open_form(socket, session, cohort_ids) do
    socket
    |> assign(:editing, session)
    |> assign(:week_mask, session.week_mask || all_weeks(socket))
    |> assign(:cohort_ids, cohort_ids)
    |> assign(:form, to_form(Catalog.change_session(session)))
  end

  defp all_weeks(socket), do: Enum.to_list(1..socket.assigns.term.weeks_count)

  @impl true
  def handle_event("filter", params, socket) do
    filters = Map.merge(@empty_filters, Map.take(params, Map.keys(@empty_filters)))
    {:noreply, push_patch(socket, to: sessions_path(socket.assigns, filters), replace: true)}
  end

  def handle_event("reset_filters", _params, socket),
    do:
      {:noreply,
       push_patch(socket, to: sessions_path(socket.assigns, @empty_filters), replace: true)}

  def handle_event("week_mask_changed", %{"preset" => preset}, socket) do
    weeks = all_weeks(socket)

    mask =
      case preset do
        "odd" -> Enum.filter(weeks, &(rem(&1, 2) == 1))
        "even" -> Enum.filter(weeks, &(rem(&1, 2) == 0))
        _all -> weeks
      end

    {:noreply, assign(socket, :week_mask, mask)}
  end

  def handle_event("week_mask_changed", %{"week" => week}, socket) do
    week = String.to_integer(week)
    mask = socket.assigns.week_mask

    mask = if week in mask, do: List.delete(mask, week), else: Enum.sort([week | mask])
    {:noreply, assign(socket, :week_mask, mask)}
  end

  def handle_event("selection_changed", %{"selected" => cohort_ids}, socket),
    do: {:noreply, assign(socket, :cohort_ids, cohort_ids)}

  def handle_event("save", %{"session" => params}, socket) do
    attrs =
      params
      |> Map.put("term_id", socket.assigns.term.id)
      |> Map.put("week_mask", socket.assigns.week_mask)
      |> Map.put("cohort_ids", socket.assigns.cohort_ids)

    result =
      case socket.assigns.editing do
        %Session{id: nil} -> Catalog.create_session(attrs)
        session -> Catalog.update_session(session, Map.delete(attrs, "term_id"))
      end

    case result do
      {:ok, _session} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Session saved."))
         |> push_patch(to: sessions_path(socket.assigns, socket.assigns.filters))
         |> load_sessions()}

      {:error, reason} ->
        {:noreply, Errors.put(socket, reason, as: :form)}
    end
  end

  def handle_event("delete_prompt", %{"id" => id}, socket),
    do: {:noreply, assign(socket, :deleting, Catalog.get_session!(id, socket.assigns.term.id))}

  def handle_event("delete_cancel", _params, socket),
    do: {:noreply, assign(socket, :deleting, nil)}

  def handle_event("delete_confirm", _params, socket) do
    case Catalog.delete_session(socket.assigns.deleting) do
      {:ok, _session} ->
        {:noreply,
         socket
         |> assign(:deleting, nil)
         |> put_flash(:info, gettext("Session deleted."))
         |> load_sessions()}

      {:error, reason} ->
        {:noreply, socket |> assign(:deleting, nil) |> Errors.put(reason)}
    end
  end

  defp load_sessions(socket) do
    filters = query_filters(socket.assigns.filters)
    count = Catalog.count_sessions(socket.assigns.term.id, filters)
    pages = max(ceil(count / 100), 1)
    page = min(socket.assigns.page, pages)
    sessions = Catalog.list_sessions(socket.assigns.term.id, filters, page: page, per_page: 100)

    socket
    |> assign(:count, count)
    |> assign(:page, page)
    |> assign(:pages, pages)
    |> stream(:sessions, sessions, reset: true)
  end

  defp query_filters(filters) do
    %{
      course_id: filters["course_id"],
      teacher_id: filters["teacher_id"],
      cohort_id: filters["cohort_id"],
      slot_profile_id: filters["slot_profile_id"],
      unplaced_in_plan: filters["unplaced_in_plan"],
      without_profile: filters["without_profile"] == "true"
    }
  end

  defp sessions_path(assigns, filters, page \\ 1) do
    params =
      filters
      |> Map.put("page", page)
      |> Map.put("return_to", assigns.return_to)
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Map.new()

    ~p"/terms/#{assigns.term}/sessions?#{params}"
  end

  # Course components are shared across terms.
  defp component_options do
    Catalog.list_course_components()
    |> Enum.map(fn component ->
      {"#{component.course.code}: #{component_kind_label(component.kind)}", component.id}
    end)
    |> Enum.sort()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={Nav.sections(@term)}
      current_path={~p"/terms/#{@term}/sessions"}
      terms={@terms}
      current_term={@term}
    >
      <.link :if={@return_to} navigate={@return_to} class="btn mb-4">{gettext("Return to timetable")}</.link>
      <.page_header title={gettext("Sessions")}>
        <:actions>
          <.link patch={~p"/terms/#{@term}/sessions/new"} class="btn btn-primary">
            <.icon name="hero-plus" class="size-4" /> {gettext("New session")}
          </.link>
        </:actions>
      </.page_header>

      <div class={["grid gap-4", @editing && "lg:grid-cols-[3fr_2fr]"]}>
        <div class="min-w-0">
          <.toolbar>
            <form id="session-filters" phx-change="filter" class="flex flex-wrap items-center gap-2">
              <select aria-label={gettext("Course")} name="course_id" class="select select-bordered">
                <option value="all">{gettext("All courses")}</option>
                <option
                  :for={course <- @courses}
                  value={course.id}
                  selected={@filters["course_id"] == course.id}
                >
                  {course.code}
                </option>
              </select>
              <select aria-label={gettext("Teacher")} name="teacher_id" class="select select-bordered">
                <option value="all">{gettext("All teachers")}</option>
                <option
                  :for={teacher <- @teachers}
                  value={teacher.id}
                  selected={@filters["teacher_id"] == teacher.id}
                >
                  {teacher.name}
                </option>
              </select>
              <select aria-label={gettext("Group")} name="cohort_id" class="select select-bordered">
                <option value="all">{gettext("All groups")}</option>
                <option
                  :for={cohort <- @cohorts}
                  value={cohort.id}
                  selected={@filters["cohort_id"] == cohort.id}
                >
                  {cohort.name}
                </option>
              </select>
              <select
                aria-label={gettext("Time profile")}
                name="slot_profile_id"
                class="select select-bordered"
              >
                <option value="all">{gettext("Any profile")}</option>
                <option
                  :for={profile <- @profiles}
                  value={profile.id}
                  selected={@filters["slot_profile_id"] == profile.id}
                >
                  {slot_profile_label(profile)}
                </option>
              </select>
              <select name="unplaced_in_plan" aria-label={gettext("Placement status")} class="select">
                <option value="all">{gettext("Any placement status")}</option>
                <option
                  :for={plan <- @plans}
                  value={plan.id}
                  selected={@filters["unplaced_in_plan"] == plan.id}
                >
                  {gettext("Unplaced in %{plan}", plan: plan.name)}
                </option>
              </select>
              <label class="label cursor-pointer gap-2 type-detail">
                <input
                  type="checkbox"
                  name="without_profile"
                  value="true"
                  checked={@filters["without_profile"] == "true"}
                  class="checkbox checkbox-sm"
                /> {gettext("No profile")}
              </label>
            </form>
            <:actions>
              <span class="type-detail text-base-content">
                {ngettext("%{count} session", "%{count} sessions", @count, count: @count)}
              </span>
              <button class="btn btn-ghost" phx-click="reset_filters">{gettext("Reset filters")}</button>
            </:actions>
          </.toolbar>

          <nav
            :if={@pages > 1}
            class="flex items-center gap-2 my-4"
            aria-label={gettext("Session pages")}
          >
            <.link :if={@page > 1} patch={sessions_path(assigns, @filters, @page - 1)} class="btn">{gettext(
              "Previous"
            )}</.link>
            <span class="type-detail">{gettext("Page %{page} of %{pages}", page: @page, pages: @pages)}</span>
            <.link
              :if={@page < @pages}
              patch={sessions_path(assigns, @filters, @page + 1)}
              class="btn"
            >{gettext("Next")}</.link>
          </nav>
          <.table
            id="sessions"
            rows={@streams.sessions}
            stream
            row_id={fn {dom_id, _session} -> dom_id end}
            row_item={fn {_dom_id, session} -> session end}
            empty_message={gettext("No matching sessions. Change the filters.")}
          >
            <:col :let={session} label={gettext("Course")}>
              <span class="font-semibold">{session.course_component.course.code}</span>
              <span class="ml-1 type-detail text-base-content">
                {component_kind_label(session.course_component.kind)}
              </span>
            </:col>
            <:col :let={session} label={gettext("Teacher")}>{session.teacher.name}</:col>
            <:col :let={session} label={gettext("Groups")}>
              <span class="flex flex-wrap gap-1">
                <span :for={cohort <- session.cohorts} class="badge badge-ghost badge-md">
                  {cohort.name}
                </span>
              </span>
            </:col>
            <:col :let={session} label={gettext("Weeks")}>
              <span :if={session.automatic_weeks}>{gettext("Automatic")}</span>
              <.teaching_weeks
                :if={!session.automatic_weeks}
                weeks={session.week_mask}
                total={@term.weeks_count}
              />
            </:col>
            <:col :let={session} label={gettext("Time slots")} numeric>{session.duration_slots}</:col>
            <:col :let={session} label={gettext("Profile")}>
              <span :if={session.slot_profile} class="badge badge-ghost badge-md">
                {slot_profile_label(session.slot_profile)}
              </span>
              <span :if={is_nil(session.slot_profile)} class="type-detail text-base-content">
                {gettext("No time profile")}
              </span>
            </:col>
            <:action :let={session}>
              <.link patch={~p"/terms/#{@term}/sessions/#{session}/edit"} class="btn btn-ghost">
                {gettext("Edit")}
              </.link>
              <button
                class="btn btn-ghost text-error"
                phx-click="delete_prompt"
                phx-value-id={session.id}
              >
                {gettext("Delete")}
              </button>
            </:action>
          </.table>
        </div>

        <.details_panel
          :if={@editing}
          class="order-first lg:order-last"
          title={if @editing.id, do: gettext("Edit session"), else: gettext("New session")}
          subtitle={gettext("Create a separate session for each parallel group.")}
          on_close={JS.patch(~p"/terms/#{@term}/sessions")}
        >
          <.form
            for={@form}
            id="session-form"
            phx-mounted={JS.focus_first(to: "#session-form")}
            phx-submit="save"
            class="flex flex-col gap-4"
          >
            <.input
              field={@form[:course_component_id]}
              type="select"
              label={gettext("Teaching type")}
              prompt={gettext("Choose a teaching type")}
              options={@components}
            />
            <.input
              field={@form[:teacher_id]}
              type="select"
              label={gettext("Teacher")}
              prompt={gettext("Choose a teacher")}
              options={Enum.map(@teachers, &{&1.name, &1.id})}
            />
            <div class="grid grid-cols-2 gap-2">
              <.input
                field={@form[:duration_slots]}
                type="number"
                label={gettext("Consecutive time slots")}
                min="1"
              />
              <.input field={@form[:sequence_group]} type="text" label={gettext("Related blocks")} />
            </div>
            <.input
              field={@form[:slot_profile_id]}
              type="select"
              label={gettext("Time profile")}
              prompt={gettext("No restriction")}
              options={Enum.map(@profiles, &{slot_profile_label(&1), &1.id})}
            />

            <div>
              <p class="label-text mb-1 block type-detail">
                {if @editing.automatic_weeks,
                  do: gettext("Restrict available weeks"),
                  else: gettext("Teaching weeks")}
              </p>
              <.week_selector id="session-weeks" weeks={@week_mask} total={@term.weeks_count} />
            </div>

            <div>
              <p class="label-text mb-1 block type-detail">{gettext("Groups")}</p>
              <p class="mb-2 type-detail text-base-content">
                {gettext("For a shared session, select all attending groups.")}
              </p>
              <.transfer_list
                id="session-cohorts"
                available={cohort_items(@cohorts, @cohort_ids, false)}
                selected={cohort_items(@cohorts, @cohort_ids, true)}
                available_label={gettext("Other groups")}
                selected_label={gettext("Attending")}
              />
            </div>

            <div class="flex gap-2 pt-2">
              <.button variant="primary" phx-disable-with={gettext("Saving")}>
                {gettext("Save")}
              </.button>
              <.link patch={~p"/terms/#{@term}/sessions"} class="btn btn-ghost">
                {gettext("Cancel")}
              </.link>
            </div>
          </.form>
        </.details_panel>
      </div>

      <.alert_dialog
        :if={@deleting}
        title={gettext("Delete this session?")}
        message={gettext("Sessions scheduled in a draft or published plan cannot be deleted.")}
        confirm_label={gettext("Delete session")}
        on_confirm="delete_confirm"
        on_cancel="delete_cancel"
      />
    </Layouts.app>
    """
  end

  defp cohort_items(cohorts, selected_ids, selected?) do
    ids = MapSet.new(selected_ids)

    cohorts
    |> Enum.filter(&(MapSet.member?(ids, &1.id) == selected?))
    |> Enum.map(&%{id: &1.id, label: &1.name})
  end
end
