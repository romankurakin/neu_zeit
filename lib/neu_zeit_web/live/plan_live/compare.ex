defmodule NeuZeitWeb.PlanLive.Compare do
  @moduledoc """
  Compares two plans of a term, so an administrator can choose between variants.

  The first plan is the state before and the second the state after, for example
  the active plan and a draft that would replace it. Each changed session links
  to its board in either plan.
  """
  use NeuZeitWeb, :live_view

  alias NeuZeit.{Catalog, Planning}
  alias NeuZeit.Planning.{Comparison, Plan}
  alias NeuZeitWeb.Nav

  @doc "The comparison of two plans of `term`."
  def path(term, before, after_),
    do: ~p"/terms/#{term}/plans/compare?#{[before: before.id, after: after_.id]}"

  @doc """
  Orders two plans for comparison: the active plan first, otherwise the older plan.

  A draft is usually a copy that would replace the active plan or its source.
  """
  def ordered(plans) do
    Enum.sort_by(plans, &{&1.status != "active", DateTime.to_unix(&1.inserted_at), &1.id})
  end

  @impl true
  def mount(%{"term_id" => term_id}, _session, socket) do
    term = Catalog.get_term!(term_id)

    {:ok,
     socket
     |> assign(:page_title, gettext("Compare plans"))
     |> assign(:term, term)
     |> assign(:terms, Catalog.list_terms())
     |> assign(:grid, NeuZeit.Config.grid!(term))
     |> assign(:plans, Planning.list_plans(term.id))
     |> assign(:comparison, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    plans = socket.assigns.plans
    before = plan_param(plans, params["before"], plans |> ordered() |> List.first())
    after_ = plan_param(plans, params["after"], Enum.find(plans, &(&1 != before)))
    by = if params["by"] == "group", do: "group", else: "teacher"

    {:noreply,
     socket
     |> assign(:before_plan, before)
     |> assign(:after_plan, after_)
     |> assign(:by, by)
     |> compare()}
  end

  # An unknown plan is not found, as on the board, rather than silently replaced.
  defp plan_param(_plans, value, default) when value in [nil, ""], do: default

  defp plan_param(plans, id, _default),
    do: Enum.find(plans, &(&1.id == id)) || raise(Ecto.NoResultsError, queryable: Plan)

  # Grouping only changes the view, so the plans are compared again only when they change.
  defp compare(%{assigns: %{before_plan: nil}} = socket), do: assign(socket, :comparison, nil)
  defp compare(%{assigns: %{after_plan: nil}} = socket), do: assign(socket, :comparison, nil)

  defp compare(socket) do
    %{before_plan: before, after_plan: after_, comparison: comparison, by: by} = socket.assigns

    comparison =
      if comparison && comparison.before.id == before.id && comparison.after.id == after_.id,
        do: comparison,
        else: Planning.compare_plans(before.id, after_.id)

    socket
    |> assign(:comparison, comparison)
    |> assign(:counts, Comparison.counts(comparison))
    |> assign(
      :groups,
      Comparison.group(comparison, if(by == "group", do: :cohort, else: :teacher))
    )
  end

  @impl true
  def handle_event("select_plans", %{"before" => before, "after" => after_}, socket),
    do: {:noreply, push_patch(socket, to: compare_path(socket.assigns, before, after_))}

  def handle_event("group", %{"by" => by}, socket),
    do: {:noreply, push_patch(socket, to: compare_path(%{socket.assigns | by: by}))}

  defp compare_path(assigns, before \\ nil, after_ \\ nil) do
    params = [
      before: before || assigns.before_plan.id,
      after: after_ || assigns.after_plan.id,
      by: assigns.by
    ]

    ~p"/terms/#{assigns.term}/plans/compare?#{params}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={Nav.sections(@term)}
      current_path={~p"/terms/#{@term}/plans"}
      terms={@terms}
      current_term={@term}
    >
      <.page_header title={gettext("Compare plans")} />

      <.empty_state
        :if={!@comparison}
        title={gettext("No second plan to compare")}
        message={gettext("Copy a plan to a draft, then compare the two.")}
        icon="hero-clipboard-document-list"
      >
        <:actions>
          <.link navigate={~p"/terms/#{@term}/plans"} class="btn btn-primary">{gettext("Plans")}</.link>
        </:actions>
      </.empty_state>

      <div :if={@comparison} class="flex flex-col gap-4">
        <form id="compare-plans" phx-change="select_plans" class="flex flex-wrap items-end gap-x-4">
          <div class="w-full sm:w-60">
            <.input
              type="select"
              id="compare-before"
              name="before"
              label={gettext("Before")}
              options={plan_options(@plans)}
              value={@before_plan.id}
            />
          </div>
          <div class="w-full sm:w-60">
            <.input
              type="select"
              id="compare-after"
              name="after"
              label={gettext("After")}
              options={plan_options(@plans)}
              value={@after_plan.id}
            />
          </div>
          <.link
            id="compare-swap"
            patch={compare_path(assigns, @after_plan.id, @before_plan.id)}
            class="btn mb-1"
          >
            {gettext("Swap")}
          </.link>
        </form>

        <.card title={gettext("Quality")}>
          <p class="type-detail">
            {gettext("Quality totals add up groups and teachers over all teaching weeks.")}
          </p>
          <.table
            id="compare-totals"
            rows={@comparison.totals}
            row_id={&"compare-total-#{&1.key}"}
          >
            <:col :let={row} label="">{metric_label(row.key)}</:col>
            <:col :let={row} label={gettext("Before")} numeric>{row.before}</:col>
            <:col :let={row} label={gettext("After")} numeric>{row.after}</:col>
            <:col :let={row} label={gettext("Change")} numeric><.delta value={row.delta} /></:col>
          </.table>
        </.card>

        <.card
          title={gettext("Changed sessions")}
          subtitle={
            gettext("Moved: %{moved}, Newly placed: %{placed}, No longer placed: %{unplaced}",
              moved: @counts.moved,
              placed: @counts.placed,
              unplaced: @counts.unplaced
            )
          }
        >
          <:header_actions :if={@comparison.changes != []}>
            <form id="compare-grouping" phx-change="group">
              <label class="sr-only" for="compare-by">{gettext("View")}</label>
              <select id="compare-by" name="by" class="select">
                <option value="teacher" selected={@by == "teacher"}>{gettext("By teacher")}</option>
                <option value="group" selected={@by == "group"}>{gettext("By group")}</option>
              </select>
            </form>
          </:header_actions>

          <.empty_state
            :if={@comparison.changes == []}
            title={gettext("No placement differences")}
            icon="hero-check-circle"
          />

          <%!--
            The table keeps a header row for each teacher or group, which needs a
            spanning cell that the shared table component does not offer.
            Below 36rem the plan columns fold into the session cell, so no row scrolls.
          --%>
          <div :if={@comparison.changes != []} class="@container">
            <div class="card card-border overflow-x-auto border-base-300 bg-base-100">
              <table id="compare-changes" class="table">
                <thead>
                  <tr>
                    <th scope="col" class="text-left">{gettext("Session")}</th>
                    <th scope="col" class="hidden text-left @min-[36rem]:table-cell">
                      {gettext("Before")}
                    </th>
                    <th scope="col" class="hidden text-left @min-[36rem]:table-cell">
                      {gettext("After")}
                    </th>
                  </tr>
                </thead>
                <tbody :for={group <- @groups} id={"compare-group-#{group.id || "none"}"}>
                  <tr class="bg-base-200">
                    <th colspan="3" scope="rowgroup" class="text-left">
                      <span class="type-heading">{group.name || gettext("No group assigned")}</span>
                      <span
                        :for={metric <- group.quality}
                        class="ml-3 type-detail font-normal whitespace-nowrap"
                      >
                        {metric_label(metric.key)}: <.delta value={metric.delta} />
                      </span>
                    </th>
                  </tr>
                  <tr
                    :for={change <- group.changes}
                    id={"compare-change-#{group.id || "none"}-#{change.session.id}"}
                    data-change={change.kind}
                    data-session-id={change.session.id}
                    class="hover:bg-base-200/60"
                  >
                    <td class="align-top">
                      <p class="font-semibold">
                        {course_title(change.session.course_component.course)}
                      </p>
                      <p>{component_kind_label(change.session.course_component)}</p>
                      <p :if={@by == "teacher"}>
                        {Enum.map_join(change.session.cohorts, ", ", & &1.name)}
                      </p>
                      <p :if={@by == "group"}>{change.session.teacher.name}</p>
                      <dl class="mt-2 grid grid-cols-[auto_1fr] gap-x-2 gap-y-1 @min-[36rem]:hidden">
                        <dt>{gettext("Before")}:</dt>
                        <dd>
                          <.position
                            term={@term}
                            grid={@grid}
                            plan={@comparison.before}
                            change={change}
                            side={:before}
                          />
                        </dd>
                        <dt>{gettext("After")}:</dt>
                        <dd>
                          <.position
                            term={@term}
                            grid={@grid}
                            plan={@comparison.after}
                            change={change}
                            side={:after}
                          />
                        </dd>
                      </dl>
                    </td>
                    <td class="hidden align-top @min-[36rem]:table-cell">
                      <.position
                        term={@term}
                        grid={@grid}
                        plan={@comparison.before}
                        change={change}
                        side={:before}
                      />
                    </td>
                    <td class="hidden align-top @min-[36rem]:table-cell">
                      <.position
                        term={@term}
                        grid={@grid}
                        plan={@comparison.after}
                        change={change}
                        side={:after}
                      />
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  # Where a session runs in one of the plans. It opens that plan's board with the
  # session selected, as locating a check does. An unplaced session opens in the
  # tray, in the week it runs in the other plan.
  attr :term, :map, required: true
  attr :grid, :map, required: true
  attr :plan, :map, required: true
  attr :change, :map, required: true
  attr :side, :atom, required: true, values: [:before, :after]

  defp position(assigns) do
    placement = Map.fetch!(assigns.change, assigns.side)
    other = Map.fetch!(assigns.change, if(assigns.side == :before, do: :after, else: :before))
    week = List.first((placement || other).week_mask)
    # Only the new position is emphasized, so the eye goes to what changed.
    fields = if assigns.side == :after, do: assigns.change.fields, else: []

    assigns =
      assigns
      |> assign(:placement, placement)
      |> assign(:fields, fields)
      |> assign(
        :path,
        ~p"/terms/#{assigns.term}/plans/#{assigns.plan}?#{[tab: "board", week: week, session: assigns.change.session.id]}"
      )

    ~H"""
    <.link
      navigate={@path}
      class="link-hover block"
      title={gettext("Show in timetable")}
      data-plan-id={@plan.id}
    >
      <span :if={!@placement} class={@side == :after && "text-warning"}>{gettext("Not placed")}</span>
      <span :if={@placement} class="flex flex-col tabular-nums">
        <span class={(:day in @fields or :time in @fields) && "font-semibold"}>
          {day_label(Enum.at(@grid.days, @placement.day - 1))} {time_range(
            @grid,
            @placement.slot,
            @placement.duration_slots
          )}
        </span>
        <span class={:room in @fields && "font-semibold"}>{room_label(@placement.room)}</span>
        <.teaching_weeks
          weeks={@placement.week_mask}
          total={@term.weeks_count}
          compact
          class={:weeks in @fields && "font-semibold"}
        />
      </span>
    </.link>
    """
  end

  # Every compared value is better lower, so a rise is a warning and a fall a success.
  attr :value, :integer, required: true

  defp delta(assigns) do
    ~H"""
    <span class={[
      "tabular-nums",
      @value > 0 && "text-warning",
      @value < 0 && "text-success"
    ]}>{if @value > 0, do: "+#{@value}", else: @value}</span>
    """
  end

  defp plan_options(plans),
    do: Enum.map(plans, &{"#{&1.name} (#{status_label(&1.status)})", &1.id})

  defp metric_label(:unplaced), do: gettext("Unplaced")
  defp metric_label(:checks), do: gettext("Checks")
  defp metric_label(:warnings), do: gettext("Warnings")
  defp metric_label(:gaps), do: gettext("Gaps")
  defp metric_label(:isolated_days), do: gettext("Days with one session")
  defp metric_label(:long_days), do: gettext("Long days")
  defp metric_label(:building_transitions), do: gettext("Building changes")
end
