defmodule NeuZeitWeb.TermLive.Show do
  @moduledoc """
  Shows term readiness and a dated calendar for non-teaching days.

  Readiness rows report data checks and link to the relevant settings.
  Some rows require administrator review.
  """
  use NeuZeitWeb, :live_view

  alias NeuZeit.{Catalog, Planning}
  alias NeuZeit.Solver.PlanRuns
  alias NeuZeit.Planning.Readiness
  alias NeuZeitWeb.Nav

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    term = Catalog.get_term!(id)

    plan = Readiness.default_plan(term.id)

    {:ok,
     socket
     |> assign(:page_title, term.name)
     |> assign(:term, term)
     |> assign(:plan, plan)
     |> assign(:latest_plan, plan)
     |> assign(:drafts, Enum.filter(Planning.list_plans(id), &(&1.status == "draft")))
     |> assign(:generation_plan, "")
     |> assign(:generation_blocked, false)
     |> assign(:terms, Catalog.list_terms())
     |> assign(:report, Readiness.report(term.id, plan && plan.id))}
  end

  defp select_generation(socket, id) do
    blocked =
      id != "" &&
        Enum.any?(Planning.check_plan(id), &(!String.starts_with?(&1.type, "external_")))

    plan = Enum.find(socket.assigns.drafts, &(&1.id == id))

    assign(socket,
      generation_plan: id,
      generation_blocked: blocked,
      plan: plan,
      report: Readiness.report(socket.assigns.term.id, plan && plan.id)
    )
  end

  @impl true
  def handle_params(params, _uri, socket) do
    selected = Enum.find(socket.assigns.drafts, &(&1.id == params["plan_id"]))
    {:noreply, select_generation(socket, if(selected, do: selected.id, else: ""))}
  end

  @impl true
  def handle_event("generation_plan", %{"plan_id" => id}, socket) do
    if id == "" || Enum.any?(socket.assigns.drafts, &(&1.id == id)) do
      {:noreply, select_generation(socket, id)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("generate", _params, socket) do
    term = socket.assigns.term

    if Catalog.count_sessions(term.id) == 0 do
      {:noreply,
       put_flash(socket, :error, gettext("Add teaching load before generating a timetable."))}
    else
      result =
        if socket.assigns.generation_plan == "" do
          Planning.create_plan(%{
            term_id: term.id,
            name: gettext("Draft %{n}", n: length(Planning.list_plans(term.id)) + 1)
          })
        else
          case Enum.find(
                 Planning.list_plans(term.id),
                 &(&1.id == socket.assigns.generation_plan && &1.status == "draft")
               ) do
            nil -> {:error, {:conflict, gettext("Create a draft to edit this plan.")}}
            plan -> {:ok, plan}
          end
        end

      case result do
        {:ok, plan} ->
          case PlanRuns.start_solve(plan.id) do
            {:ok, _} -> {:noreply, push_navigate(socket, to: ~p"/terms/#{term}/plans/#{plan}")}
            {:error, reason} -> {:noreply, Errors.put(socket, reason)}
          end

        {:error, reason} ->
          {:noreply, Errors.put(socket, reason)}
      end
    end
  end

  def handle_event("toggle_excluded_date", %{"date" => iso}, socket) do
    date = Date.from_iso8601!(iso)
    term = socket.assigns.term

    result =
      if date in term.excluded_dates do
        Catalog.remove_excluded_date(term, date)
      else
        Catalog.add_excluded_date(term, date)
      end

    case result do
      {:ok, term} ->
        {:noreply,
         socket
         |> assign(:term, term)
         |> assign(
           :report,
           Readiness.report(term.id, socket.assigns.plan && socket.assigns.plan.id)
         )}

      {:error, reason} ->
        # Show the context error when a dated change prevents excluding the date.
        {:noreply, Errors.put(socket, reason)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={Nav.sections(@term)}
      current_path={~p"/terms/#{@term}"}
      terms={@terms}
      current_term={@term}
    >
      <.page_header title={@term.name} subtitle={"#{@term.starts_on} - #{@term.ends_on}"}>
        <:actions>
          <.link
            navigate={
              if @latest_plan,
                do: ~p"/terms/#{@term}/plans/#{@latest_plan}",
                else: ~p"/terms/#{@term}/plans"
            }
            class="btn btn-primary"
          >{if @latest_plan, do: gettext("Open timetable"), else: gettext("Plans")}</.link>
        </:actions>
      </.page_header>

      <.empty_state
        :if={count_for(@report, :week_masks, [:detail, :total]) == 0}
        title={gettext("No teaching load yet")}
        message={gettext("Set the teaching load and constraints, then generate a timetable.")}
        icon="hero-academic-cap"
      >
        <:actions>
          <.link navigate={~p"/terms/#{@term}/workload/new"} class="btn btn-primary">{gettext(
            "Add teaching load"
          )}</.link>
        </:actions>
      </.empty_state>
      <.card
        :if={count_for(@report, :week_masks, [:detail, :total]) > 0}
        class="mb-4"
        title={gettext("Checks")}
      >
        <p :if={@plan} class="type-detail">
          {gettext("Plan")}:
          <.link navigate={~p"/terms/#{@term}/plans/#{@plan}"} class="link">{@plan.name}</.link>
        </p>
        <.check_results id="readiness">
          <:item
            :for={row <- @report}
            status={row.status}
            label={label_for(row.key)}
            detail={detail_for(row)}
            navigate={route_for(row, @term, @plan)}
            action_label={action_label_for(row.key)}
          >
            {row.count}
          </:item>
        </.check_results>
      </.card>

      <.card title={gettext("Timetable")} class="mb-4">
        <.form
          for={%{}}
          id="generation-plan"
          phx-change="generation_plan"
          class="flex flex-wrap items-end gap-4"
        >
          <.input
            type="select"
            name="plan_id"
            value={@generation_plan}
            label={gettext("Plan")}
            options={[{gettext("New draft"), ""} | Enum.map(@drafts, &{&1.name, &1.id})]}
          />
          <.button
            type="button"
            variant="primary"
            phx-click="generate"
            phx-disable-with={gettext("Generating timetable")}
            disabled={@generation_blocked || count_for(@report, :week_masks, [:detail, :total]) == 0}
          >
            {gettext("Generate timetable")}
          </.button>
        </.form>
        <p :if={@generation_blocked} class="mt-4">
          {gettext("Resolve rule violations on the Checks tab before generating the timetable.")}
        </p>
        <p :if={@generation_plan != ""} class="mt-4">
          {gettext(
            "Calculation replaces unlocked placements in this draft. Locked sessions stay in place."
          )}
        </p>
      </.card>

      <.card id="teaching-calendar" title={gettext("Teaching calendar")}>
        <:header_actions>
          <.link navigate={~p"/terms/#{@term}/edit"} class="btn">{gettext("Edit dates")}</.link>
        </:header_actions>
        <p class="mb-4 type-detail text-base-content">
          {gettext(
            "Select non-teaching dates. Dated sessions on these dates are omitted. You cannot add or move dated sessions to them."
          )}
        </p>

        <.term_calendar term={@term} />

        <p class="mt-4 flex items-center gap-2 type-detail text-base-content">
          <span class="inline-block h-3 w-6 rounded-field bg-error/15"></span>
          {gettext("Non-teaching dates")}
        </p>
      </.card>
    </Layouts.app>
    """
  end

  defp count_for(report, key, path) do
    case Enum.find(report, &(&1.key == key)) do
      nil -> 0
      row -> get_in(row, path) || 0
    end
  end

  defp label_for(:term_dates), do: gettext("Term dates and non-teaching dates")
  defp label_for(:placeholder_teachers), do: gettext("Teacher names")
  defp label_for(:teacher_availability), do: gettext("Teacher availability")
  defp label_for(:merge_candidates), do: gettext("Possible duplicate sessions")
  defp label_for(:aggregate_cohorts), do: gettext("Group names")
  defp label_for(:week_masks), do: gettext("Weeks and durations")
  defp label_for(:room_pools), do: gettext("Allowed rooms")
  defp label_for(:slot_profiles), do: gettext("Time profiles")
  defp label_for(:locks), do: gettext("Locked placements")
  defp label_for(:unplaced), do: gettext("Session placement")
  defp label_for(:hard_checks), do: gettext("Scheduling conflicts")
  defp label_for(:advisories), do: gettext("Possible group overlaps")

  defp detail_for(%{key: :term_dates, detail: detail}),
    do:
      gettext("Teaching weeks: %{weeks}. Non-teaching dates: %{excluded}.",
        weeks: detail.weeks,
        excluded: detail.excluded_dates
      )

  defp detail_for(%{key: :placeholder_teachers, count: 0}),
    do: gettext("No short teacher codes found.")

  defp detail_for(%{key: :placeholder_teachers, detail: detail}),
    do:
      gettext("Abbreviated names: %{names}",
        names: Enum.map_join(detail.teachers, ", ", & &1.name)
      )

  defp detail_for(%{key: :teacher_availability, count: 0}),
    do: gettext("Availability is entered for every teacher.")

  defp detail_for(%{key: :teacher_availability, count: count, detail: detail}),
    do:
      gettext(
        "Teachers without time restrictions: %{count} of %{total}. Check that this is correct.",
        count: count,
        total: detail.total
      )

  defp detail_for(%{key: :merge_candidates, count: 0}),
    do: gettext("No possible duplicate sessions found.")

  defp detail_for(%{key: :merge_candidates, detail: detail}),
    do:
      gettext("Same teaching type, teacher, weeks and duration: %{codes}",
        codes: Enum.map_join(detail.groups, ", ", & &1.course_code)
      )

  defp detail_for(%{key: :aggregate_cohorts, count: 0}),
    do: gettext("No group names flagged for review.")

  defp detail_for(%{key: :aggregate_cohorts, detail: detail}),
    do:
      gettext("Check these group names: %{names}",
        names: Enum.map_join(detail.cohorts, ", ", & &1.name)
      )

  defp detail_for(%{key: :week_masks, detail: %{automatic: automatic} = detail})
       when automatic > 0,
       do:
         gettext(
           "Automatic week selection for %{automatic} meetings. Fixed weeks for %{fixed} sessions.",
           automatic: automatic,
           fixed: detail.every_week + detail.partial
         )

  defp detail_for(%{key: :week_masks, detail: detail}),
    do:
      gettext("Weekly sessions: %{full}. Selected weeks only: %{partial}.",
        full: detail.every_week,
        partial: detail.partial
      )

  defp detail_for(%{key: :room_pools, count: 0}),
    do: gettext("Each teaching type has two to five allowed rooms.")

  defp detail_for(%{key: :room_pools, detail: detail}),
    do:
      gettext("%{narrow} with a single room, %{broad} with more than five.",
        narrow: length(detail.narrow),
        broad: length(detail.broad)
      )

  defp detail_for(%{key: :slot_profiles, count: 0}),
    do: gettext("Every session has a time profile.")

  defp detail_for(%{key: :slot_profiles, count: count, detail: detail}),
    do:
      gettext("Sessions without a time profile: %{count} of %{total}.",
        count: count,
        total: detail.total
      )

  defp detail_for(%{key: key, status: :unknown})
       when key in [:locks, :unplaced, :hard_checks, :advisories],
       do: gettext("No plan selected.")

  defp detail_for(%{key: :locks, count: 0}), do: gettext("No placements are locked.")

  defp detail_for(%{key: :locks, count: count}),
    do: ngettext("%{count} locked placement", "%{count} locked placements", count, count: count)

  defp detail_for(%{key: :unplaced, count: 0}), do: gettext("All sessions are scheduled.")

  defp detail_for(%{key: :unplaced, count: count, detail: detail}),
    do:
      gettext("Sessions still to schedule: %{count} of %{total}.",
        count: count,
        total: detail.total
      )

  defp detail_for(%{key: :hard_checks, count: 0}), do: gettext("No rule violations found.")

  defp detail_for(%{key: :hard_checks, detail: detail}),
    do:
      gettext("By type: %{types}",
        types:
          Enum.map_join(detail.by_type, ", ", fn {type, n} ->
            "#{NeuZeitWeb.Scheduling.Diagnostics.type_label(type)} (#{n})"
          end)
      )

  defp detail_for(%{key: :advisories, count: 0}),
    do: gettext("No group overlaps flagged.")

  defp detail_for(%{key: :advisories, count: count}),
    do:
      ngettext("%{count} overlap needs verifying", "%{count} overlaps need verifying", count,
        count: count
      )

  defp detail_for(_row), do: nil

  # An action helps only where the row asks for work, and the work is done elsewhere.
  defp route_for(%{status: :ok}, _term, _plan), do: nil

  defp route_for(%{key: key}, term, plan) when key in [:unplaced, :hard_checks, :advisories] do
    # Without a plan these rows have nothing to open. The timetable card below picks one.
    plan && ~p"/terms/#{term}/plans/#{plan}?#{%{tab: plan_tab(key)}}"
  end

  defp route_for(%{key: key}, term, _plan), do: route_for(key, term)

  defp plan_tab(:hard_checks), do: "checks"
  defp plan_tab(:advisories), do: "advisories"
  defp plan_tab(:unplaced), do: "board"

  defp route_for(:placeholder_teachers, term),
    do: Nav.with_return(~p"/people?tab=teachers", ~p"/terms/#{term}")

  defp route_for(:aggregate_cohorts, term),
    do: Nav.with_return(~p"/people?tab=cohorts", ~p"/terms/#{term}")

  defp route_for(:room_pools, term), do: Nav.with_return(~p"/courses", ~p"/terms/#{term}")
  defp route_for(:teacher_availability, term), do: ~p"/terms/#{term}/availability"
  # A profile belongs to a session, so the work is on the session, not on the profile.
  defp route_for(:slot_profiles, term), do: ~p"/terms/#{term}/sessions"
  defp route_for(:merge_candidates, term), do: ~p"/terms/#{term}/sessions"
  defp route_for(:week_masks, term), do: ~p"/terms/#{term}/workload"
  defp route_for(_key, _term), do: nil

  # Each action carries the name of the page it opens.
  defp action_label_for(key) when key in [:placeholder_teachers, :aggregate_cohorts],
    do: gettext("Teachers and groups")

  defp action_label_for(key) when key in [:slot_profiles, :merge_candidates],
    do: gettext("Sessions")

  defp action_label_for(:room_pools), do: gettext("Courses")
  defp action_label_for(:teacher_availability), do: gettext("Availability")
  defp action_label_for(:week_masks), do: gettext("Teaching load")
  defp action_label_for(:unplaced), do: gettext("Semester template")
  defp action_label_for(:hard_checks), do: gettext("Checks")
  defp action_label_for(:advisories), do: gettext("Warnings")
  defp action_label_for(_key), do: nil
end
