defmodule NeuZeitWeb.PlanLive.BoardEditor do
  @moduledoc false
  use NeuZeitWeb, :html
  import NeuZeitWeb.PlanLive.Workspace

  attr :board, :map, required: true
  attr :plan, :map, required: true
  attr :term, :map, required: true
  attr :workspace, :map, required: true
  attr :week, :integer, required: true
  attr :busiest, :integer, required: true
  attr :lens, :string, required: true
  attr :resource_id, :string, required: true
  attr :search, :string, required: true
  attr :tray_limit, :integer, required: true
  attr :selected_session_id, :string, required: true
  attr :selected_placement, :map, required: true
  attr :selected_session, :map, required: true
  attr :grid, :map, required: true
  attr :legal, :map, required: true
  attr :target, :any, required: true
  attr :assessment, :list, required: true
  attr :explanation, :map, required: true
  attr :cohorts, :list, required: true
  attr :teachers, :list, required: true
  attr :rooms, :list, required: true

  def board(assigns) do
    assigns =
      assigns
      |> assign(:visible, visible_placements(assigns.board, assigns.lens, assigns.resource_id))
      |> assign(:tray, tray_sessions(assigns))
      |> assign(:resources, resource_options(assigns))
      |> assign(
        :allowed_weeks,
        case Enum.find(assigns.board.placements, &(&1.session_id == assigns.selected_session_id)) do
          nil -> []
          placement -> placement.session.week_mask
        end
      )

    ~H"""
    <div>
      <p
        :if={
          Enum.any?(@board.placements, &(!&1.session.automatic_weeks && length(&1.week_mask) > 1)) ||
            Enum.any?(@board.unplaced, &(!&1.automatic_weeks && length(&1.week_mask) > 1))
        }
        class="mb-4 type-detail"
        id="template-scope"
      >
        {gettext("Moving a session changes every week it runs.")}
      </p>
      <.toolbar>
        <.week_picker
          weeks_count={@term.weeks_count}
          current={@week}
          busiest={@busiest}
          event="select_week"
        />
        <:actions>
          <form id="board-filters" phx-change="filter_board" class="flex flex-wrap gap-2">
            <label class="sr-only" for="board-lens">{gettext("View")}</label>
            <select id="board-lens" name="lens" class="select">
              <option
                :for={
                  {label, value} <- [
                    {gettext("All"), "all"},
                    {gettext("By group"), "cohort"},
                    {gettext("By teacher"), "teacher"},
                    {gettext("By room"), "room"}
                  ]
                }
                value={value}
                selected={@lens == value}
              >
                {label}
              </option>
            </select>
            <label :if={@lens != "all"} class="sr-only" for="board-resource">{gettext("Resource")}</label>
            <select :if={@lens != "all"} id="board-resource" name="resource" class="select">
              <option value="">{gettext("Everything")}</option>
              <option
                :for={resource <- @resources}
                value={resource.id}
                selected={resource.id == @resource_id}
              >
                {resource.name}
              </option>
            </select>
          </form>
        </:actions>
      </.toolbar>

      <details
        :if={@board.unplaced != []}
        class="collapse collapse-arrow bg-base-100 border border-base-300 mb-4"
        open
      >
        <summary class="collapse-title font-semibold">
          {ngettext("%{count} unplaced", "%{count} unplaced", length(@board.unplaced),
            count: length(@board.unplaced)
          )}
        </summary>
        <div class="collapse-content">
          <form id="tray-search" phx-change="filter_board" class="mb-2">
            <label for="session-search" class="sr-only">{gettext("Find an unplaced session")}</label>
            <input
              id="session-search"
              name="q"
              value={@search}
              phx-debounce="200"
              type="search"
              class="input w-full"
              placeholder={gettext("Course, teacher or group")}
            />
          </form>
          <div class="max-h-72 overflow-y-auto">
            <.session_tray
              id="board-tray"
              sessions={Enum.take(@tray, @tray_limit)}
              weeks_count={@term.weeks_count}
              selected_session_id={@selected_session_id}
              on_select={JS.push_focus() |> JS.push("select_session")}
              empty_message={gettext("No matching sessions. Change the filters.")}
            />
            <button :if={length(@tray) > @tray_limit} class="btn mt-2" phx-click="more_unplaced">{gettext(
              "Show more (%{count} remaining)",
              count: length(@tray) - @tray_limit
            )}</button>
          </div>
        </div>
      </details>
      <div class={[
        "grid items-start gap-4",
        @selected_session && "lg:grid-cols-[minmax(0,1fr)_20rem]"
      ]}>
        <div class="min-w-0">
          <.timetable
            id="board"
            placements={@visible}
            week={@week}
            weeks_count={@term.weeks_count}
            grid={@grid}
            legal={@legal}
            highlighting={@selected_session_id != nil}
            selected_session_id={@selected_session_id}
            selected_placement_id={@selected_placement && @selected_placement.id}
            on_select={JS.push_focus() |> JS.push("select_session")}
            on_place="inspect_position"
            readonly={@plan.status != "draft"}
          />
        </div>
        <.session_inspector
          :if={@selected_session}
          plan={@plan}
          term={@term}
          workspace={@workspace}
          selected_session={@selected_session}
          selected_placement={@selected_placement}
          explanation={@explanation}
          grid={@grid}
          target={@target}
          legal={@legal}
          assessment={@assessment}
          allowed_weeks={@allowed_weeks}
        />
      </div>
    </div>
    """
  end

  attr :plan, :map, required: true
  attr :term, :map, required: true
  attr :workspace, :map, required: true
  attr :selected_session, :map, required: true
  attr :selected_placement, :map, required: true
  attr :explanation, :map, required: true
  attr :grid, :map, required: true
  attr :target, :any, required: true
  attr :legal, :map, required: true
  attr :assessment, :list, required: true

  attr :allowed_weeks, :list, default: []

  def session_inspector(assigns) do
    ~H"""
    <div
      id="session-inspector"
      phx-mounted={JS.focus_first(to: "#session-inspector")}
      phx-remove={JS.pop_focus()}
      class="min-w-0 order-first lg:order-last lg:sticky lg:top-20 lg:max-h-[calc(100dvh-6rem)] lg:overflow-y-auto"
    >
      <.details_panel
        title={course_title(@selected_session.course_component.course)}
        subtitle={component_kind_label(@selected_session.course_component)}
        on_close="clear_selection"
      >
        <section class="flex flex-col gap-2">
          <div class="flex flex-col gap-1">
            <p>{@selected_session.teacher.name}</p>
            <p class="type-detail">{Enum.map_join(@selected_session.cohorts, ", ", & &1.name)}</p>
            <div class="flex flex-wrap items-baseline gap-x-2 gap-y-1 type-detail">
              <.teaching_weeks weeks={@selected_session.week_mask} total={@term.weeks_count} />
              <p>
                {ngettext(
                  "%{count} time slot",
                  "%{count} time slots",
                  @selected_session.duration_slots,
                  count: @selected_session.duration_slots
                )}
              </p>
            </div>
          </div>
          <p class="type-detail font-semibold" id="selection-scope">
            {gettext("Changes apply to: %{weeks}",
              weeks: weeks_label(@selected_session.week_mask, @term.weeks_count)
            )}
          </p>
          <.link
            navigate={
              ~p"/terms/#{@term}/workload/#{@selected_session.workload_id}/edit?return_to=#{workspace_path(@workspace)}"
            }
            class="link type-detail"
          >{gettext("Edit teaching load")}</.link>
        </section>
        <section class="border-t border-base-300 pt-4">
          <.placement_rules
            explanation={@explanation}
            term={@term}
            on_unlock={@plan.status == "draft" && "toggle_lock"}
            return_to={workspace_path(@workspace)}
          />
        </section>
        <section
          :if={@plan.status == "draft"}
          class="flex flex-col gap-2 border-t border-base-300 pt-4"
        >
          <h3 class="type-heading">{gettext("Time and room")}</h3>
          <div class="flex flex-col gap-4">
            <form
              :if={@selected_placement && @selected_session.automatic_weeks}
              id="placement-week"
              phx-change="change_week"
              class="flex flex-col gap-1"
            >
              <label for="placement-week-number" class="label type-detail">{gettext(
                "Week (saved immediately)"
              )}</label>
              <select
                id="placement-week-number"
                name="week"
                class="select w-full"
                disabled={@selected_placement.locked}
              >
                <option
                  :for={week <- @allowed_weeks}
                  value={week}
                  selected={week in @selected_placement.week_mask}
                >
                  {week}
                </option>
              </select>
            </form>
            <form
              :if={@selected_placement && @plan.status == "draft"}
              id="placement-room"
              phx-change="change_room"
              class="flex flex-col gap-1"
            >
              <label for="placement-room-id" class="label type-detail">{gettext(
                "Room (saved immediately)"
              )}</label>
              <select
                id="placement-room-id"
                name="room_id"
                class="select w-full"
                disabled={@selected_placement.locked}
              >
                <option
                  :for={room <- @selected_session.course_component.allowed_rooms}
                  value={room.id}
                  selected={room.id == @selected_placement.room_id}
                >
                  {room.name}
                </option>
              </select>
            </form>
            <div :if={@plan.status == "draft"} class="flex flex-col gap-4">
              <form
                id="inspect-position"
                phx-change="inspect_position"
                phx-submit="inspect_position"
                class="flex flex-col gap-2"
              >
                <label class="sr-only" for="target-day">{gettext("Day")}</label>
                <select id="target-day" name="day" class="select w-full">
                  <option
                    :for={{day, index} <- Enum.with_index(@grid.days, 1)}
                    value={index}
                    selected={
                      if @target,
                        do: elem(@target, 0) == index,
                        else: @selected_placement && @selected_placement.day == index
                    }
                  >
                    {day_label(day)}
                  </option>
                </select>
                <label class="sr-only" for="target-slot">{gettext("Time")}</label>
                <select id="target-slot" name="slot" class="select w-full">
                  <option
                    :for={{slot, index} <- Enum.with_index(@grid.slots, 1)}
                    value={index}
                    selected={
                      if @target,
                        do: elem(@target, 1) == index,
                        else: @selected_placement && @selected_placement.slot == index
                    }
                  >
                    {slot.start}
                  </option>
                </select>
                <button type="submit" class="btn w-full">{gettext("Check constraints")}</button>
              </form>
              <details class="type-detail">
                <summary class="cursor-pointer">
                  {gettext("Available starts: %{count}", count: map_size(@legal))}
                </summary>
                <div class="grid grid-cols-2 gap-2 mt-2">
                  <button
                    :for={{{day, slot}, _rooms} <- Enum.sort(@legal)}
                    class="btn w-full justify-between tabular-nums"
                    phx-click="inspect_position"
                    phx-value-day={day}
                    phx-value-slot={slot}
                  >
                    <span>{day_label(Enum.at(@grid.days, day - 1))}</span>
                    <span>{Enum.at(@grid.slots, slot - 1).start}</span>
                  </button>
                </div>
              </details>
              <div :if={@target} id="position-preview" class="flex flex-col gap-2" aria-live="polite">
                <p class="font-semibold">
                  {day_label(Enum.at(@grid.days, elem(@target, 0) - 1))} {NeuZeitWeb.Scheduling.SessionCard.time_range(
                    @grid,
                    elem(@target, 1),
                    @selected_session.duration_slots
                  )}
                </p>
                <p :if={@assessment == []} class="type-detail">
                  {gettext("No rooms are allowed. Add rooms to this teaching type.")}
                </p>
                <div
                  :for={choice <- @assessment}
                  class="border border-base-300 rounded-box p-2 type-detail"
                >
                  <p class="font-semibold">{choice.room.name}</p>
                  <ul :if={choice.errors != []} class="text-error">
                    <li :for={error <- choice.errors}>{Errors.entry_message(error)}</li>
                  </ul>
                  <button
                    :if={choice.errors == []}
                    class="btn mt-1"
                    phx-click="apply_position"
                    phx-value-room-id={choice.room.id}
                    disabled={@selected_placement && @selected_placement.locked}
                  >
                    {gettext("Place here")}
                  </button>
                </div>
              </div>
            </div>
          </div>
        </section>
        <:actions>
          <button
            :if={@selected_placement && @plan.status == "draft"}
            class="btn"
            phx-click="toggle_lock"
          >
            {if @selected_placement.locked, do: gettext("Unlock"), else: gettext("Lock")}
          </button>
          <button
            :if={@selected_placement && @plan.status == "draft"}
            class="btn"
            phx-click="unplace_selected"
            disabled={@selected_placement.locked}
          >{gettext("Remove from timetable")}</button>
        </:actions>
      </.details_panel>
    </div>
    """
  end
end
