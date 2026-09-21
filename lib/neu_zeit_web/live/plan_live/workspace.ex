defmodule NeuZeitWeb.PlanLive.Workspace do
  @moduledoc false
  use NeuZeitWeb, :verified_routes
  import NeuZeitWeb.Scheduling.Labels, only: [course_title: 1]

  def location(assigns) do
    Map.take(assigns, [
      :term,
      :plan_id,
      :tab,
      :week,
      :lens,
      :resource_id,
      :selected_session_id,
      :search
    ])
  end

  def parse_week(value, total) do
    case Integer.parse(value || "1") do
      {week, ""} -> min(max(week, 1), total)
      _ -> 1
    end
  end

  def workspace_path(assigns, changes \\ %{}) do
    params =
      Map.merge(
        %{
          "tab" => assigns.tab,
          "week" => assigns.week,
          "lens" => assigns.lens,
          "resource" => assigns.resource_id,
          "session" => assigns.selected_session_id,
          "q" => assigns.search
        },
        changes
      )
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Map.new()

    ~p"/terms/#{assigns.term}/plans/#{assigns.plan_id}?#{params}"
  end

  def visible_placements(board, lens, id) do
    Enum.filter(board.placements, fn p ->
      case {lens, id} do
        {_, nil} -> true
        {"cohort", id} -> Enum.any?(p.session.cohorts, &(&1.id == id))
        {"teacher", id} -> p.session.teacher_id == id
        {"room", id} -> p.room_id == id
        _ -> true
      end
    end)
  end

  def resource_options(assigns) do
    case assigns.lens do
      "cohort" -> assigns.cohorts
      "teacher" -> assigns.teachers
      "room" -> assigns.rooms
      _ -> []
    end
  end

  def tray_sessions(assigns) do
    q = String.downcase(assigns.search)

    Enum.filter(assigns.board.unplaced, fn s ->
      text =
        Enum.join(
          [
            course_title(s.course_component.course),
            s.course_component.course.code,
            s.teacher.name | Enum.map(s.cohorts, & &1.name)
          ],
          " "
        )

      matches =
        case {assigns.lens, assigns.resource_id} do
          {"cohort", id} when not is_nil(id) ->
            Enum.any?(s.cohorts, &(&1.id == id))

          {"teacher", id} when not is_nil(id) ->
            s.teacher_id == id

          {"room", id} when not is_nil(id) ->
            s.delivery_mode != :online &&
              NeuZeit.Catalog.CourseComponent.room_allowed?(s.course_component, id)

          _ ->
            true
        end

      matches && String.contains?(String.downcase(text), q)
    end)
  end

  def busiest_week(board, term) do
    1..term.weeks_count
    |> Enum.max_by(fn week -> Enum.count(board.placements, &(week in &1.week_mask)) end, fn ->
      1
    end)
  end
end
