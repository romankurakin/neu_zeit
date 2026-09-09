defmodule NeuZeitWeb.PlanLive.Reports do
  @moduledoc false
  use NeuZeitWeb, :html
  import NeuZeitWeb.PlanLive.Workspace, only: [workspace_path: 2]

  attr :tab, :string, required: true
  attr :board, :map, required: true
  attr :plan, :map, required: true
  attr :term, :map, required: true
  attr :workspace, :map, required: true
  attr :quality, :map, required: true
  attr :coverage, :list, required: true

  def reports(assigns) do
    ~H"""
      <div :if={@tab == "quality"} class="flex flex-col gap-4">

        <.empty_state :if={@quality.rooms == []} title={gettext("No scheduled sessions")}>
          <:actions><.link patch={workspace_path(@workspace, %{"tab" => "board"})} class="btn btn-primary">{gettext("Open timetable")}</.link></:actions>
        </.empty_state>

        <p :if={@quality.rooms != []} class="type-detail">{gettext("Totals cover all teaching weeks. Gaps are counted in time slots.")} {gettext("Long days span %{count} or more time slots with gaps.", count: length(NeuZeit.Config.grid!().slots) - 1)}</p>
        <.card :if={@quality.cohorts != []} title={gettext("Groups")}>
          <.quality_table id="quality-cohorts" rows={@quality.cohorts} term={@term} lens="cohort" workspace={@workspace} />
        </.card>
        <.card :if={@quality.teachers != []} title={gettext("Teachers")}>
          <.quality_table id="quality-teachers" rows={@quality.teachers} term={@term} lens="teacher" workspace={@workspace} />
        </.card>

        <.card :if={@quality.sequences != []} title={gettext("Related blocks")}>
          <.table id="quality-sequences" rows={@quality.sequences} row_id={&"seq-#{&1.group}"}>
            <:col :let={row} label={gettext("Group")}>{row.group}</:col>
            <:col :let={row} label={gettext("Blocks")} numeric>{row.placements}</:col>
            <:col :let={row} label={gettext("Days")}>{Enum.map_join(row.days, ", ", &day_label(Enum.at(NeuZeit.Config.grid!().days, &1 - 1)))}</:col>
            <:col :let={row} label={gettext("Adjacent")}>
              <.status_indicator
                status={if row.adjacent, do: :ok, else: :warning}
                label={if row.adjacent, do: gettext("Side by side"), else: gettext("Split apart")}
              />
            </:col>
          </.table>
        </.card>

        <.card :if={@quality.rooms != []} title={gettext("Rooms")}>
          <.table id="quality-rooms" rows={@quality.rooms} row_id={&"quality-room-#{&1.id}"}>
            <:col :let={row} label={gettext("Room")} class="whitespace-nowrap"><.link patch={workspace_path(@workspace, %{"tab" => "board", "lens" => "room", "resource" => row.id, "week" => row.first_week, "session" => nil, "q" => nil})} class="link font-semibold" title={gettext("Show in timetable")}>{row.name}</.link></:col>
            <:col :let={row} label={gettext("Sessions")} numeric>{row.placements}</:col>
            <:col :let={row} label={gettext("Occupied time slots")} numeric>{row.occupied_cells}</:col>

          </.table>
        </.card>

      </div>

      <div :if={@tab == "coverage"} class="flex flex-col gap-4">
        <p>{gettext("Academic hours (%{minutes} min)", minutes: @term.academic_hour_minutes)}</p>
        <p class="type-detail text-base-content">
          {gettext(
            "Courses not entered here are not included in the totals."
          )}
        </p>

        <p class="type-detail font-semibold">{@plan.name}, {if @plan.status == "active", do: gettext("Published calendar, including active changes"), else: gettext("Calendar from the template, without one-off changes")}</p>
        <.table id="coverage" rows={@coverage} row_id={&"coverage-#{&1.course_id}-#{&1.cohort_id || "unassigned"}"}>
          <:col :let={row} label={gettext("Course")}><span class="font-semibold">{row.code}</span></:col>
          <:col :let={row} label={gettext("Title")}>{row.title}</:col>
          <:col :let={row} label={gettext("Group")}>{row.cohort_name || gettext("No group assigned")}</:col>
          <:col :let={row} label={gettext("Credits")} numeric>{row.credits}</:col>
          <:col :let={row} label={gettext("Required hours")} numeric>{Float.round(row.required_hours * 60 / @term.academic_hour_minutes, 1)}</:col>
          <:col :let={row} label={gettext("Planned hours")} numeric>{Float.round(row.planned_hours * 60 / @term.academic_hour_minutes, 1)}</:col>
          <:col :let={row} label={gettext("Calendar hours")} numeric>{Float.round(row.calendar_hours * 60 / @term.academic_hour_minutes, 1)}</:col>
          <:col :let={row} label={gettext("Difference")} numeric>{Float.round(row.delta_hours * 60 / @term.academic_hour_minutes, 1)}</:col>
          <:col :let={row} label={gettext("Status")}><.status_indicator status={row.status} /></:col>
        </.table>
      </div>

      <div :if={@tab == "checks"}>
        <.diagnostic_list
          id="checks"
          entries={@board.checks}
          severity={:error}
          empty_title={gettext("No rule violations found in scheduled sessions.")}
          on_locate="locate"
        />
      </div>

      <div :if={@tab == "advisories"}>
        <p class="mb-4 type-detail text-base-content">
          {gettext(
            "Check whether these groups share students. These warnings do not block publication."
          )}
        </p>
        <.diagnostic_list
          id="advisories"
          entries={@board.advisories}
          severity={:advisory}
          empty_title={gettext("No group overlaps flagged")}
          on_locate="locate"
        />
      </div>

    """
  end

  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :term, :map, required: true

  attr :lens, :string, required: true
  attr :workspace, :map, required: true

  defp quality_table(assigns) do
    ~H"""
    <.table id={@id} rows={@rows} row_id={&"#{@id}-#{&1.id}"}>
      <:col :let={row} label={gettext("Name")} class="whitespace-nowrap"><.link patch={workspace_path(@workspace, %{"tab" => "board", "lens" => @lens, "resource" => row.id, "week" => row.first_week, "session" => nil, "q" => nil})} class="link font-semibold" title={gettext("Show in timetable")}>{row.name}</.link></:col>
      <:col :let={row} label={gettext("Gaps")} numeric>
        <span class={row.gaps > 0 && "text-warning"}>{row.gaps}</span>
      </:col>
      <:col :let={row} label={gettext("Days with one session")} numeric class="whitespace-normal">
        <span class={row.isolated_days > 0 && "text-warning"}>{row.isolated_days}</span>
      </:col>
      <:col :let={row} label={gettext("Long days")} numeric class="whitespace-normal">{row.long_days}</:col>
      <:col :let={row} label={gettext("Building changes")} numeric class="whitespace-normal">
        <span class={row.building_transitions > 0 && "text-warning"}>{row.building_transitions}</span>
      </:col>
      <:col :let={row} label={gettext("Weeks")}>
        <.teaching_weeks weeks={row.weeks} total={@term.weeks_count} />
      </:col>
      <:col :let={row} label={gettext("Longest break (weeks)")} numeric class="whitespace-normal">
        <span class={row.calendar_gap >= 4 && "text-error"}>{row.calendar_gap}</span>
      </:col>

    </.table>
    """
  end
end
