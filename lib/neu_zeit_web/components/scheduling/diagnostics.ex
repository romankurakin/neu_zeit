defmodule NeuZeitWeb.Scheduling.Diagnostics do
  @moduledoc """
  Components for rule violations, warnings, placement rules and calculation failures.
  """
  use NeuZeitWeb, :ui_component
  import NeuZeitWeb.Scheduling.Labels, only: [slot_profile_label: 1]

  import NeuZeitWeb.UI.Status, only: [status_indicator: 1]

  import NeuZeitWeb.UI.EmptyState, only: [empty_state: 1]

  import NeuZeitWeb.UI.Table, only: [table: 1]

  @doc """
  Groups diagnostics by type. Selecting an entry locates its placements on the board.
  """
  attr :id, :string, required: true
  attr :entries, :list, required: true
  attr :severity, :atom, default: :error
  attr :empty_title, :string, required: true
  attr :empty_message, :string, default: nil
  attr :on_locate, :any, default: nil

  def diagnostic_list(assigns) do
    assigns = assign(assigns, :grouped, Enum.group_by(assigns.entries, & &1.type))

    ~H"""
    <div id={@id}>
      <.empty_state
        :if={@entries == []}
        title={@empty_title}
        message={@empty_message}
        icon="hero-check-circle"
      />

      <div :for={{type, entries} <- @grouped} class="mb-4">
        <h3 class="mb-2 flex items-center gap-2 type-heading">
          <.status_indicator status={@severity} label={type_label(type)} />
          <span class="text-base-content">
            {ngettext("%{count} occurrence", "%{count} occurrences", length(entries),
              count: length(entries)
            )}
          </span>
        </h3>

        <.table
          id={"#{@id}-#{type}"}
          rows={Enum.with_index(entries)}
          row_id={fn {_entry, index} -> "#{@id}-#{type}-#{index}" end}
          row_item={fn {entry, _index} -> entry end}
        >
          <:col :let={entry} label={gettext("Checks")} class="w-full min-w-64 whitespace-normal">
            {NeuZeitWeb.UI.Errors.entry_message(entry)}
          </:col>
          <:col :let={entry} :if={Enum.any?(entries, & &1[:cohorts])} label={gettext("Groups")}>
            <span class="flex flex-wrap gap-1">
              <span :for={name <- List.flatten(entry[:cohorts] || [])} class="badge badge-ghost badge-md">
                {name}
              </span>
            </span>
          </:col>
          <:action :let={entry} :if={@on_locate}>
            <button
              :if={entry[:placement_ids] not in [nil, []]}
              class="link type-detail"
              phx-click={@on_locate}
              phx-value-placement-id={List.first(entry.placement_ids)}
            >
              {gettext("Show in timetable")}
            </button>
          </:action>
        </.table>
      </div>
    </div>
    """
  end

  @doc "Localized diagnostic headings shared by the checks and readiness screens."
  def type_label("grid_bounds"), do: gettext("Outside the timetable grid")
  def type_label("week_mask_mismatch"), do: gettext("Weeks differ from the session")
  def type_label("duration_mismatch"), do: gettext("Duration differs from the session")
  def type_label("room_not_allowed"), do: gettext("Room is not allowed for this teaching type")
  def type_label("time_not_allowed"), do: gettext("Start time is outside the time profile")
  def type_label("teacher_unavailable"), do: gettext("Teacher is not available then")
  def type_label("duplicate_session"), do: gettext("Session placed more than once")
  def type_label("room_conflict"), do: gettext("Room has overlapping sessions")
  def type_label("teacher_conflict"), do: gettext("Teacher has overlapping sessions")
  def type_label("cohort_conflict"), do: gettext("Group has overlapping sessions")
  def type_label("unverified_cohort_overlap"), do: gettext("Group may overlap with a subgroup")
  def type_label("external_room_conflict"), do: gettext("Room booked in another term")
  def type_label("external_teacher_conflict"), do: gettext("Teacher booked in another term")
  def type_label("external_cohort_conflict"), do: gettext("Group booked in another term")
  def type_label(type), do: type

  @doc """
  Shows the rules that apply to a placement and links to their settings.
  """
  attr :explanation, :map, required: true
  attr :term, :map, required: true
  attr :on_unlock, :any, default: nil
  attr :return_to, :string, default: nil

  def placement_rules(assigns) do
    ~H"""
    <div class="flex flex-col gap-2 type-detail">
      <h3 class="type-heading">
        {gettext("Placement rules")}
      </h3>

      <div :if={@explanation.locked} class="flex items-center justify-between gap-2 rounded-field border border-warning/40 bg-warning/10 px-2 py-1">
        <span class="flex items-center gap-1">
          <.icon name="hero-lock-closed" class="size-4 text-warning" />
          {gettext("Locked in place by hand")}
        </span>
        <button :if={@on_unlock} class="link type-detail shrink-0" phx-click={@on_unlock}>
          {gettext("Unlock")}
        </button>
      </div>

      <div :if={@explanation.slot_profile} class="flex flex-wrap items-start gap-x-2 gap-y-1">
        <span>
          {gettext("Time profile: %{name}", name: slot_profile_label(@explanation.slot_profile))}
          <span class="text-base-content">
            ({ngettext("%{count} start time", "%{count} start times", @explanation.slot_profile.starts,
              count: @explanation.slot_profile.starts
            )})
          </span>
        </span>
        <.link navigate={~p"/terms/#{@term}/slot-profiles/#{@explanation.slot_profile.id}/edit?return_to=#{@return_to}"} class="link type-detail shrink-0">
          {gettext("Edit rule")}
        </.link>
      </div>

      <div :if={@explanation.availability} class="flex flex-wrap items-start gap-x-2 gap-y-1">
        <span>
          {ngettext("Teacher available in %{count} time slot", "Teacher available in %{count} time slots", @explanation.availability.cells)}
        </span>
        <.link navigate={~p"/terms/#{@term}/availability/#{@explanation.availability.teacher_id}?return_to=#{@return_to}"} class="link type-detail shrink-0">
          {gettext("Edit rule")}
        </.link>
      </div>

      <div class="flex flex-wrap items-start gap-x-2 gap-y-1">
        <span>
          {ngettext(
            "%{count} allowed room",
            "%{count} allowed rooms",
            length(@explanation.room_pool.rooms),
            count: length(@explanation.room_pool.rooms)
          )}
        </span>
        <.link navigate={~p"/courses/#{@explanation.room_pool.course_id}?return_to=#{@return_to}"} class="link type-detail shrink-0">{gettext("Edit rule")}</.link>
      </div>

      <p class="type-detail text-base-content">
        {ngettext(
          "%{count} possible start time with a free room.",
          "%{count} possible start times with a free room.",
          @explanation.alternatives,
          count: @explanation.alternatives
        )}
      </p>
    </div>
    """
  end

  @doc """
  Shows a calculation failure and links to input rules the administrator can review.
  """
  attr :status, :string, required: true
  attr :message, :string, default: nil
  attr :term, :map, required: true
  attr :locked_count, :integer, default: 0
  attr :narrow_pools, :integer, default: 0
  attr :unconstrained, :integer, default: 0

  def solver_feedback(assigns) do
    ~H"""
    <div class="rounded-box border border-warning/40 bg-warning/5 p-4">
      <h3 class="mb-1 flex items-center gap-2 type-heading">
        <.icon name="hero-wrench-screwdriver" class="size-5 text-warning" />
        {title_for(@status)}
      </h3>

      <p class="mb-2 type-detail text-base-content">
        {if @status in ["INFEASIBLE", "TIMEOUT", "BUSY"], do: advice_for(@status), else: @message || advice_for(@status)}
      </p>

      <ul :if={@status in ["INFEASIBLE", "TIMEOUT"]} class="flex flex-col gap-1 type-detail">
        <li class="flex flex-wrap items-start gap-x-2 gap-y-1">
          <span>
            {ngettext("%{count} locked placement", "%{count} locked placements", @locked_count,
              count: @locked_count
            )}
          </span>
          <span class="type-detail text-base-content">{gettext("stays fixed during calculation")}</span>
        </li>
        <li class="flex flex-wrap items-start gap-x-2 gap-y-1">
          <span>
            {ngettext(
              "%{count} teaching type allows only one room",
              "%{count} teaching types allow only one room",
              @narrow_pools,
              count: @narrow_pools
            )}
          </span>
          <.link navigate={~p"/courses"} class="link type-detail shrink-0">{gettext("Allowed rooms")}</.link>
        </li>
        <li class="flex flex-wrap items-start gap-x-2 gap-y-1">
          <span>{gettext("Groups that may combine separate sections")}</span>
          <.link navigate={~p"/people?tab=cohorts"} class="link type-detail shrink-0">
            {gettext("Groups")}
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  defp title_for("INFEASIBLE"), do: gettext("No timetable fits the current rules")
  defp title_for("TIMEOUT"), do: gettext("Time limit reached")
  defp title_for("BUSY"), do: gettext("Calculation in progress")
  defp title_for(_status), do: gettext("Calculation failed")

  defp advice_for("INFEASIBLE"),
    do:
      gettext(
        "Check whether locked placements, allowed rooms and time restrictions match your requirements."
      )

  defp advice_for("TIMEOUT"),
    do: gettext("Review time restrictions and allowed rooms, then try again.")

  defp advice_for("BUSY"),
    do: gettext("Wait for the current calculation to finish.")

  defp advice_for(_status),
    do: gettext("Calculation could not finish. Try again.")
end
