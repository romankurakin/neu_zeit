defmodule NeuZeitWeb.SessionLive.Index do
  @moduledoc "Read-only sessions generated from teaching load."
  use NeuZeitWeb, :live_view

  alias NeuZeit.{Catalog, Planning}
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
    push_navigate(socket,
      to:
        Nav.with_return(~p"/terms/#{socket.assigns.term}/workload/new", socket.assigns.return_to)
    )
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    session = Catalog.get_session!(id, socket.assigns.term.id)

    push_navigate(socket,
      to:
        Nav.with_return(
          ~p"/terms/#{socket.assigns.term}/workload/#{session.workload_id}/edit",
          socket.assigns.return_to
        )
    )
  end

  defp apply_action(socket, :index, _params), do: socket

  @impl true
  def handle_event("filter", params, socket) do
    filters = Map.merge(@empty_filters, Map.take(params, Map.keys(@empty_filters)))
    {:noreply, push_patch(socket, to: sessions_path(socket.assigns, filters), replace: true)}
  end

  def handle_event("reset_filters", _params, socket),
    do:
      {:noreply,
       push_patch(socket, to: sessions_path(socket.assigns, @empty_filters), replace: true)}

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
          <.link navigate={~p"/terms/#{@term}/workload/new"} class="btn btn-primary">
            <.icon name="hero-plus" class="size-4" /> {gettext("Add teaching load")}
          </.link>
        </:actions>
      </.page_header>

      <div class="grid gap-4">
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
                  {course_title(course)}
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
              <span class="font-semibold">{course_title(session.course_component.course)}</span>
              <span class="ml-1 type-detail text-base-content">
                {component_kind_label(session.course_component)}
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
              <.link
                navigate={
                  Nav.with_return(
                    ~p"/terms/#{@term}/workload/#{session.workload_id}/edit",
                    @return_to
                  )
                }
                class="btn btn-ghost"
              >
                {gettext("Edit")}
              </.link>
            </:action>
          </.table>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
