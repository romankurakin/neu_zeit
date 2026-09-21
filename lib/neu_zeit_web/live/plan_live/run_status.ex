defmodule NeuZeitWeb.PlanLive.RunStatus do
  @moduledoc false
  use NeuZeitWeb, :html
  import NeuZeitWeb.PlanLive.Workspace, only: [workspace_path: 2]

  attr :board, :map, required: true
  attr :term, :map, required: true
  attr :workspace, :map, required: true
  attr :solving_since, :any, required: true
  attr :tick, :integer, required: true
  attr :solver_limit, :integer, required: true
  attr :solver_blocked, :boolean, required: true
  attr :last_result, :any, required: true

  def run_status(assigns) do
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
        <.solver_feedback
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
