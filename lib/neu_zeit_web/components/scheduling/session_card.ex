defmodule NeuZeitWeb.Scheduling.SessionCard do
  @moduledoc "One teaching session, optionally placed in the timetable."
  use NeuZeitWeb, :ui_component
  alias NeuZeit.Config
  import NeuZeitWeb.Scheduling.Labels
  import NeuZeitWeb.Scheduling.TeachingWeeks

  attr :id, :string, required: true
  attr :session, :map, required: true
  attr :placement, :map, default: nil
  attr :weeks_count, :integer, required: true
  attr :selected, :boolean, default: false
  attr :on_select, :any, default: nil
  attr :style, :string, default: nil
  attr :grid, :map, default: nil

  def session_card(assigns) do
    assigns =
      assign(assigns, :grid, assigns.grid || Config.grid!(Map.get(assigns.session, :term_id)))

    ~H"""
    <.dynamic_tag
      tag_name={if @on_select, do: "button", else: "div"}
      {%{type: @on_select && "button"}}
      id={@id}
      data-session-id={@session.id}
      data-placement-id={@placement && @placement.id}
      phx-click={@on_select}
      phx-value-session-id={@session.id}
      aria-pressed={@on_select && to_string(@selected)}
      style={@style}
      class={[
        "card card-border card-xs min-w-0 w-full bg-base-100 text-left self-stretch overflow-hidden",
        "focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary",
        if(@selected, do: "border-primary bg-base-200", else: "border-base-300 hover:bg-base-200")
      ]}
    >
      <%!--
        The layout follows a calendar entry, so a week of cards fits on the board.
        The grid row already shows the time; it stays for screen readers.
      --%>
      <span class="card-body gap-1 break-words type-detail font-normal">
        <span class="flex items-start gap-1 font-semibold">
          <.icon
            :if={@placement && @placement.locked}
            name="hero-lock-closed"
            class="mt-0.5 size-4 shrink-0"
          />
          <span :if={@placement && @placement.locked} class="sr-only">{gettext("Locked")}</span>
          <span class="min-w-0">{course_title(@session.course_component.course)}</span>
        </span>
        <span :if={@placement} class="sr-only">
          {time_range(@grid, @placement.slot, @placement.duration_slots)}
        </span>
        <span class="flex flex-wrap justify-between gap-x-2">
          <span class="flex flex-wrap gap-x-2">
            <span>{component_kind_label(@session.course_component)}</span>
            <span :if={!@placement && Map.get(@session, :delivery_mode) == :online}>{gettext("Online")}</span>
          </span>
          <span :if={!@placement && Map.get(@session, :automatic_weeks, false)}>
            {gettext("Week selected automatically")}
          </span>
          <.teaching_weeks
            :if={@placement || !Map.get(@session, :automatic_weeks, false)}
            weeks={if @placement, do: @placement.week_mask, else: @session.week_mask}
            total={@weeks_count}
            compact
          />
        </span>
        <span><span class="sr-only">{gettext("Teacher")}:</span> {@session.teacher.name}</span>
        <span class="flex flex-wrap items-center gap-1">
          <span class="sr-only">{gettext("Groups")}:</span>
          <span :for={cohort <- @session.cohorts} class="badge badge-ghost badge-md">{cohort.name}</span>
          <span :if={@placement} class="ml-auto">
            <span class="sr-only">{gettext("Room")}:</span> {room_label(@placement.room)}
          </span>
        </span>
      </span>
    </.dynamic_tag>
    """
  end

  def time_range(grid, slot, duration) do
    first = Enum.at(grid.slots, slot - 1)
    last = Enum.at(grid.slots, slot + duration - 2)
    if first && last, do: "#{first.start}-#{last.end}", else: "#{slot}"
  end
end
