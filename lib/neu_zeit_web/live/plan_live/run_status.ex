defmodule NeuZeitWeb.PlanLive.RunStatus do
  @moduledoc false
  use NeuZeitWeb, :html
  import NeuZeitWeb.PlanLive.Workspace, only: [workspace_path: 2]

  import NeuZeitWeb.Scheduling.Labels,
    only: [component_kind_label: 1, course_title: 1, slot_profile_label: 1]

  alias NeuZeitWeb.Nav

  # A minimal conflict is usually short. Longer lists end with a count.
  @shown_sessions 12

  attr :board, :map, required: true
  attr :term, :map, required: true
  attr :workspace, :map, required: true
  attr :solving_since, :any, required: true
  attr :tick, :integer, required: true
  attr :solver_limit, :integer, required: true
  attr :solver_blocked, :boolean, required: true
  attr :last_result, :any, required: true

  def run_status(assigns) do
    # Elapsed-time ticks do not reload the conflict records.
    assigns =
      assign(
        assigns,
        :conflict,
        !assigns.solving_since && conflict(assigns.term, assigns.last_result)
      )

    ~H"""
    <div
      :if={@solving_since || @solver_blocked || solver_status(@last_result)}
      id="plan-run-status"
      class="mb-4 flex flex-col gap-4"
    >
      <div :if={@solving_since} role="status" class="flex flex-wrap items-center gap-2 type-detail">
        <span class="loading loading-spinner loading-sm" aria-hidden="true"></span>
        <span>{gettext("Generating timetable")}</span>
        <span>{gettext("Elapsed: %{elapsed} s. Limit: %{limit} s.",
          elapsed: elapsed(@solving_since, @tick),
          limit: @solver_limit
        )}</span>
      </div>
      <div :if={@solver_blocked && !@solving_since} class="alert alert-error">
        <span>{gettext("Resolve rule violations on the Checks tab before generating the timetable.")}</span>
        <.link patch={workspace_path(@workspace, %{"tab" => "checks"})} class="link">{gettext(
          "Checks"
        )}</.link>
      </div>
      <div :if={!@solving_since && solver_status(@last_result) != nil} class="motion-safe:enter">
        <.conflict_feedback :if={@conflict} conflict={@conflict} term={@term} workspace={@workspace} />
        <.solver_feedback
          :if={!@conflict}
          status={solver_status(@last_result)}
          message={solver_message(@last_result)}
          term={@term}
          locked_count={Enum.count(@board.placements, & &1.locked)}
          narrow_pools={narrow_pools(@board)}
        />
      </div>
    </div>
    """
  end

  attr :conflict, :map, required: true
  attr :term, :map, required: true
  attr :workspace, :map, required: true

  defp conflict_feedback(assigns) do
    assigns =
      assigns
      |> assign(:return_to, workspace_path(assigns.workspace, %{}))
      |> assign(:shown, Enum.take(assigns.conflict.sessions, @shown_sessions))
      |> assign(:hidden, max(length(assigns.conflict.sessions) - @shown_sessions, 0))

    ~H"""
    <div id="solver-conflict" class="rounded-box border border-warning/40 bg-warning/5 p-4">
      <h3 class="mb-1 flex items-center gap-2 type-heading">
        <.icon name="hero-wrench-screwdriver" class="size-5 text-warning" />
        {gettext("No timetable fits the current rules")}
      </h3>

      <p class="mb-2 type-detail text-base-content">
        {gettext(
          "These rules cannot all be met. Change at least one of them, then generate the timetable again."
        )}
      </p>

      <ul class="flex flex-col gap-1 type-detail">
        <li
          :for={rule <- @conflict.rules}
          id={"solver-conflict-#{rule.kind}-#{rule_id(rule)}"}
          class="flex flex-wrap items-start gap-x-2 gap-y-1"
        >
          <span>{rule_sentence(rule)}</span>
          <.link
            :if={rule.kind == :lock}
            patch={workspace_path(@workspace, %{"tab" => "board", "session" => rule.session.id})}
            class="link type-detail shrink-0"
          >
            {gettext("Show in timetable")}
          </.link>
          <.link
            :if={rule.kind != :lock}
            navigate={Nav.with_return(rule_path(rule, @term), @return_to)}
            class="link type-detail shrink-0"
          >
            {rule_action(rule)}
          </.link>
        </li>
      </ul>

      <p class="mt-3 mb-1 type-detail text-base-content">
        {if match?([_], @conflict.sessions),
          do: gettext("This session cannot be placed:"),
          else: gettext("These sessions cannot all be placed:")}
      </p>
      <ul id="solver-conflict-sessions" class="flex flex-wrap gap-x-3 gap-y-1 type-detail">
        <li :for={session <- @shown}>
          <.link
            navigate={
              Nav.with_return(
                ~p"/terms/#{@term}/workload/#{session.workload_id || session.id}/edit",
                @return_to
              )
            }
            class="link"
          >
            {session_label(session)}
          </.link>
        </li>
        <li :if={@hidden > 0}>
          {ngettext("and %{count} more", "and %{count} more", @hidden)}
        </li>
      </ul>
    </div>
    """
  end

  defp conflict(term, {:error, %{errors: [%{conflict: conflict} | _]}}),
    do: NeuZeit.Planning.describe_conflict(term.id, conflict)

  defp conflict(_term, _result), do: nil

  defp rule_sentence(%{kind: :teacher_availability, teacher: teacher, slots: slots}),
    do:
      ngettext(
        "%{teacher} is available in %{count} time slot.",
        "%{teacher} is available in %{count} time slots.",
        slots,
        teacher: teacher.name
      )

  defp rule_sentence(%{kind: :teacher_load, teacher: teacher}),
    do: gettext("%{teacher} cannot teach two sessions at the same time.", teacher: teacher.name)

  defp rule_sentence(%{kind: :group_load, cohort: cohort}),
    do: gettext("Group %{group} cannot attend two sessions at the same time.", group: cohort.name)

  defp rule_sentence(%{kind: :time_profile, slot_profile: profile}),
    do:
      ngettext(
        "Time profile %{name} allows %{count} start time.",
        "Time profile %{name} allows %{count} start times.",
        length(profile.cells),
        name: slot_profile_label(profile)
      )

  defp rule_sentence(%{kind: :allowed_rooms, course_component: component}),
    do:
      gettext("Allowed rooms for %{course}, %{type}: %{rooms}.",
        course: course_title(component.course),
        type: component_kind_label(component),
        rooms: component.allowed_rooms |> Enum.map(& &1.name) |> Enum.sort() |> Enum.join(", ")
      )

  defp rule_sentence(%{kind: :lock, session: session}),
    do: gettext("Locked placement: %{session}.", session: session_label(session))

  defp rule_sentence(%{kind: :non_teaching_dates}),
    do: gettext("Sessions do not take place on non-teaching dates.")

  defp rule_sentence(%{kind: :other_terms}),
    do: gettext("Teachers, groups or rooms are booked in active plans of other terms.")

  defp rule_path(%{kind: :teacher_availability, teacher: teacher}, term),
    do: ~p"/terms/#{term}/availability/#{teacher.id}"

  defp rule_path(%{kind: kind}, term) when kind in [:teacher_load, :group_load],
    do: ~p"/terms/#{term}/workload"

  defp rule_path(%{kind: :time_profile, slot_profile: profile}, term),
    do: ~p"/terms/#{term}/slot-profiles/#{profile.id}/edit"

  defp rule_path(%{kind: :allowed_rooms, course_component: component}, _term),
    do: ~p"/courses/#{component.course_id}"

  defp rule_path(%{kind: :non_teaching_dates}, term), do: ~p"/terms/#{term}/settings"
  defp rule_path(%{kind: :other_terms}, _term), do: ~p"/terms"

  # Each action carries the name of the page it opens.
  defp rule_action(%{kind: :teacher_availability}), do: gettext("Availability")

  defp rule_action(%{kind: kind}) when kind in [:teacher_load, :group_load],
    do: gettext("Teaching load")

  defp rule_action(%{kind: :time_profile}), do: gettext("Time profiles")
  defp rule_action(%{kind: :allowed_rooms}), do: gettext("Allowed rooms")
  defp rule_action(%{kind: :non_teaching_dates}), do: gettext("Term settings")
  defp rule_action(%{kind: :other_terms}), do: gettext("Terms")

  defp rule_id(%{teacher: teacher}), do: teacher.id
  defp rule_id(%{cohort: cohort}), do: cohort.id
  defp rule_id(%{slot_profile: profile}), do: profile.id
  defp rule_id(%{course_component: component}), do: component.id
  defp rule_id(%{session: session}), do: session.id
  defp rule_id(_term_wide), do: "term"

  defp session_label(session) do
    component = session.course_component

    Enum.join(
      [course_title(component.course), component_kind_label(component)] ++
        Enum.map(session.cohorts, & &1.name),
      ", "
    )
  end

  defp narrow_pools(board) do
    rooms = NeuZeit.Catalog.list_rooms()

    (Enum.map(board.placements, & &1.session) ++ board.unplaced)
    |> Enum.reject(&(&1.delivery_mode == :online))
    |> Enum.map(& &1.course_component)
    |> Enum.uniq_by(& &1.id)
    |> Enum.count(&(length(NeuZeit.Catalog.CourseComponent.room_options(&1, rooms)) == 1))
  end

  # The tick is an explicit input so LiveView updates elapsed time between solver events.
  defp elapsed(started_at, _tick), do: DateTime.diff(DateTime.utc_now(), started_at)
  # Calculation diagnostics carry the status used to select troubleshooting advice.
  defp solver_status({:error, %{errors: [%{solver_status: status} | _]}}), do: to_string(status)
  defp solver_status({:error, %{"status" => status}}), do: to_string(status)
  defp solver_status({:error, _reason}), do: "FAILED"
  defp solver_status(_result), do: nil

  defp solver_message({:error, %{errors: [entry | _]}}), do: Errors.entry_message(entry)
  defp solver_message({:error, {:conflict, _message} = reason}), do: Errors.message(reason)
  defp solver_message(_result), do: nil
end
