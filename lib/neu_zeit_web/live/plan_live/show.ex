defmodule NeuZeitWeb.PlanLive.Show do
  @moduledoc """
  The plan board, placement controls and reports.

  The week and resource filters select what is displayed. Conflict checks still
  use the full plan. Reports are loaded outside `render/1` and refreshed after changes.
  """
  use NeuZeitWeb, :live_view

  alias NeuZeit.{Catalog, Curriculum, Planning}
  alias NeuZeit.Planning.{Feasibility, Quality, Readiness}
  alias NeuZeit.Solver.PlanRuns
  alias NeuZeitWeb.Nav
  alias NeuZeitWeb.PlanLive.{BoardEditor, Publication, Reports, RunStatus, Workspace}

  import NeuZeitWeb.PlanLive.Workspace,
    only: [workspace_path: 1, workspace_path: 2, parse_week: 2, busiest_week: 2]

  @impl true
  def mount(%{"term_id" => term_id, "id" => id}, _session, socket) do
    term = Catalog.get_term!(term_id)
    Planning.get_plan!(id, term_id)
    # Subscribe before reading run state so a completion cannot fall between
    # the snapshot and the subscription when an administrator returns here.
    socket = subscribe(socket, id)

    {:ok,
     socket
     |> assign(:term, term)
     |> assign(:terms, Catalog.list_terms())
     |> assign(:grid, NeuZeit.Config.grid!())
     |> assign(:week, 1)
     |> assign(:lens, "all")
     |> assign(:cohort_id, nil)
     |> assign(:cohorts, Catalog.list_cohorts())
     |> assign(:teachers, Catalog.list_teachers())
     |> assign(:rooms, Catalog.list_rooms())
     |> assign(:resource_id, nil)
     |> assign(:search, "")
     |> assign(:tray_limit, 40)
     |> assign(:selected_session, nil)
     |> assign(:target, nil)
     |> assign(:assessment, [])
     |> assign(:explanation, nil)
     |> assign(:tab, "board")
     |> assign(:report_cache, %{})
     |> assign(:selected_session_id, nil)
     |> assign(:selected_placement, nil)
     |> assign(:legal, %{})
     |> assign(:undo, [])
     |> assign(:plan_id, id)
     |> assign(:solving_since, PlanRuns.started_at(id))
     |> assign(:last_result, PlanRuns.last_result(id))
     |> assign(:tick, 0)
     |> assign(:publishing, false)
     |> assign(:acknowledged, %{})
     |> assign(:gate, [])
     |> load_board()}
  end

  defp subscribe(socket, plan_id) do
    if connected?(socket) do
      :ok = PlanRuns.subscribe(plan_id)
      # Updates elapsed time once per second while a calculation runs.
      :timer.send_interval(1_000, self(), :tick)
    end

    socket
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab =
      if params["tab"] in ["board", "checks", "advisories", "quality", "coverage"],
        do: params["tab"],
        else: "board"

    lens =
      if params["lens"] in ["all", "cohort", "teacher", "room"], do: params["lens"], else: "all"

    socket = if tab != socket.assigns.tab, do: load_board(socket), else: socket

    socket =
      socket
      |> assign(:tab, tab)
      |> assign(:lens, lens)
      |> assign(
        :resource_id,
        if(params["resource"] in [nil, ""], do: nil, else: params["resource"])
      )
      |> assign(:cohort_id, params["resource"])
      |> assign(:week, parse_week(params["week"], socket.assigns.term.weeks_count))
      |> assign(:search, params["q"] || "")

    socket =
      if params["session"] != socket.assigns.selected_session_id,
        do: select_session(socket, params["session"]),
        else: socket

    {:noreply, load_report(socket)}
  end

  # Events

  @impl true
  def handle_event("refresh_board", _params, socket) do
    {:noreply, socket |> load_board() |> reselect(socket.assigns.selected_session_id)}
  end

  def handle_event("select_week", %{"week" => week}, socket),
    do: {:noreply, push_patch(socket, to: workspace_path(socket.assigns, %{"week" => week}))}

  def handle_event("select_lens", %{"lens" => lens}, socket),
    do:
      {:noreply,
       push_patch(socket,
         to: workspace_path(socket.assigns, %{"lens" => lens, "resource" => nil})
       )}

  def handle_event("select_cohort", %{"cohort_id" => id}, socket),
    do: {:noreply, push_patch(socket, to: workspace_path(socket.assigns, %{"resource" => id}))}

  def handle_event("filter_board", params, socket),
    do:
      {:noreply,
       push_patch(assign(socket, :tray_limit, 40),
         to: workspace_path(socket.assigns, Map.take(params, ["q", "lens", "resource"])),
         replace: true
       )}

  def handle_event("more_unplaced", _params, socket),
    do: {:noreply, update(socket, :tray_limit, &(&1 + 40))}

  def handle_event("select_session", %{"session-id" => id}, socket),
    do: {:noreply, push_patch(socket, to: workspace_path(socket.assigns, %{"session" => id}))}

  def handle_event("clear_selection", _params, socket),
    do: {:noreply, push_patch(socket, to: workspace_path(socket.assigns, %{"session" => nil}))}

  def handle_event("inspect_position", %{"day" => day, "slot" => slot}, socket) do
    case socket.assigns.selected_session do
      nil ->
        {:noreply, socket}

      session ->
        target = {String.to_integer(day), String.to_integer(slot)}
        {d, t} = target

        {:noreply,
         socket
         |> assign(:target, target)
         |> assign(:assessment, Feasibility.assess(session, socket.assigns.plan_id, d, t))}
    end
  end

  def handle_event("apply_position", %{"room-id" => room_id}, socket) do
    case socket.assigns.target do
      {day, slot} -> place(socket, socket.assigns.selected_session_id, day, slot, room_id)
      _ -> {:noreply, socket}
    end
  end

  def handle_event("unplace_selected", _params, socket),
    do: unplace(socket, socket.assigns.selected_session_id)

  def handle_event("clone_draft", _params, socket) do
    case Planning.clone_plan(socket.assigns.plan_id) do
      {:ok, plan} ->
        {:noreply, push_navigate(socket, to: ~p"/terms/#{socket.assigns.term}/plans/#{plan}")}

      {:error, reason} ->
        {:noreply, Errors.put(socket, reason)}
    end
  end

  # Click-to-place: the same operation as a drop, reachable without a pointer.
  def handle_event("place_here", %{"day" => day, "slot" => slot}, socket) do
    place(
      socket,
      socket.assigns.selected_session_id,
      String.to_integer(day),
      String.to_integer(slot)
    )
  end

  def handle_event("drop_session", %{"target" => "tray", "session-id" => session_id}, socket) do
    unplace(socket, session_id)
  end

  def handle_event(
        "drop_session",
        %{"session-id" => session_id, "day" => day, "slot" => slot},
        socket
      ) do
    place(socket, session_id, String.to_integer(day), String.to_integer(slot))
  end

  def handle_event(event, _params, %{assigns: %{selected_placement: nil}} = socket)
      when event in ["toggle_lock", "change_room", "change_week"], do: {:noreply, socket}

  def handle_event("toggle_lock", _params, socket) do
    placement = socket.assigns.selected_placement

    case Planning.update_placement(placement, %{"locked" => not placement.locked}) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> push_undo(undo_entry(placement, updated))
         |> load_board()
         |> reselect(updated.session_id)}

      {:error, reason} ->
        {:noreply, Errors.put(socket, reason)}
    end
  end

  def handle_event("change_room", %{"room_id" => room_id}, socket) do
    placement = socket.assigns.selected_placement

    case Planning.update_placement(placement, %{"room_id" => room_id}) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> push_undo(undo_entry(placement, updated))
         |> load_board()
         |> reselect(updated.session_id)}

      {:error, reason} ->
        {:noreply, Errors.put(socket, reason)}
    end
  end

  def handle_event("change_week", %{"week" => week}, socket) do
    placement = socket.assigns.selected_placement

    case Planning.update_placement(placement, %{"week_mask" => [week]}) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> push_undo(undo_entry(placement, updated))
         |> load_board()
         |> reselect(updated.session_id)
         |> push_patch(to: workspace_path(socket.assigns, %{"week" => hd(updated.week_mask)}))}

      {:error, reason} ->
        {:noreply, Errors.put(socket, reason)}
    end
  end

  def handle_event("undo", _params, socket), do: {:noreply, undo(socket)}

  def handle_event(event, _params, %{assigns: %{plan: %{status: status}}} = socket)
      when event in ["publish_open", "publish_confirm"] and status != "draft",
      do:
        {:noreply, Errors.put(socket, {:conflict, gettext("Create a draft to edit this plan.")})}

  def handle_event("publish_open", _params, socket) do
    {:noreply,
     socket
     |> assign(:publishing, true)
     |> assign(:acknowledged, %{})
     |> assign(:gate, Readiness.report(socket.assigns.term.id, socket.assigns.plan_id))}
  end

  def handle_event("publish_cancel", _params, socket),
    do: {:noreply, assign(socket, :publishing, false)}

  def handle_event("acknowledge", %{"key" => key}, socket) do
    {:noreply, update(socket, :acknowledged, &Map.update(&1, key, true, fn v -> not v end))}
  end

  def handle_event("publish_confirm", _params, socket) do
    case Planning.publish_plan(socket.assigns.plan_id) do
      {:ok, _plan} ->
        {:noreply,
         socket
         |> assign(:publishing, false)
         |> put_flash(:info, gettext("Published. The term's previous active plan is archived."))
         |> load_board()}

      {:error, reason} ->
        {:noreply, socket |> assign(:publishing, false) |> Errors.put(reason)}
    end
  end

  def handle_event("locate", %{"placement-id" => placement_id}, socket) do
    case Enum.find(socket.assigns.board.placements, &(&1.id == placement_id)) do
      nil ->
        {:noreply, socket}

      placement ->
        # Select a week in the placement mask so the target card is visible.
        week = List.first(placement.week_mask) || 1

        {:noreply,
         socket
         |> assign(:week, week)
         |> assign(:tab, "board")
         |> select_session(placement.session_id)
         |> push_patch(
           to:
             workspace_path(socket.assigns, %{
               "tab" => "board",
               "week" => week,
               "session" => placement.session_id,
               "lens" => "all",
               "resource" => nil
             })
         )}
    end
  end

  @impl true
  def handle_info(:tick, socket) do
    if socket.assigns.solving_since do
      {:noreply, update(socket, :tick, &(&1 + 1))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:solve_started, _plan_id, started_at}, socket),
    do: {:noreply, assign(socket, :solving_since, started_at)}

  def handle_info({:solve_finished, _plan_id, result}, socket) do
    socket = socket |> assign(:solving_since, nil) |> assign(:last_result, result) |> load_board()
    socket = if match?({:ok, _}, result), do: assign(socket, :undo, []), else: socket
    {:noreply, flash_result(socket, result)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp flash_result(socket, {:ok, _result}),
    do:
      put_flash(
        socket,
        :info,
        gettext("All sessions have been scheduled. Review the timetable before publishing.")
      )

  defp flash_result(socket, {:error, {:conflict, _message} = reason}),
    do: Errors.put(socket, reason)

  defp flash_result(socket, {:error, _reason}), do: socket

  # Board mutations

  defp place(socket, session_id, day, slot, room_id \\ nil)
  defp place(socket, nil, _day, _slot, _room_id), do: {:noreply, socket}

  defp place(socket, session_id, day, slot, room_id) do
    plan_id = socket.assigns.plan_id
    existing = Enum.find(socket.assigns.board.placements, &(&1.session_id == session_id))

    result =
      if existing do
        Planning.update_placement(existing, %{
          "day" => day,
          "slot" => slot,
          "room_id" => room_id || existing.room_id
        })
      else
        session = Enum.find(socket.assigns.board.unplaced, &(&1.id == session_id))

        room_id =
          room_id || first_free_room(socket, session, day, slot) ||
            (session && List.first(session.course_component.allowed_rooms) &&
               hd(session.course_component.allowed_rooms).id)

        Planning.create_placement(%{
          "plan_id" => plan_id,
          "session_id" => session_id,
          "week_mask" => [socket.assigns.week],
          "room_id" => room_id,
          "day" => day,
          "slot" => slot
        })
      end

    case result do
      {:ok, placement} ->
        {:noreply,
         socket
         |> push_undo(undo_entry(existing, placement))
         |> load_board()
         |> select_session(session_id)
         |> push_patch(to: workspace_path(socket.assigns, %{"session" => session_id}))}

      {:error, reason} ->
        socket = socket |> load_board() |> select_session(session_id)

        socket =
          if socket.assigns.selected_session do
            socket
            |> assign(:target, {day, slot})
            |> assign(
              :assessment,
              Feasibility.assess(socket.assigns.selected_session, plan_id, day, slot)
            )
          else
            socket
          end

        {:noreply, Errors.put(socket, reason)}
    end
  end

  defp unplace(socket, session_id) do
    case Enum.find(socket.assigns.board.placements, &(&1.session_id == session_id)) do
      nil ->
        {:noreply, socket}

      placement ->
        case Planning.delete_placement(placement) do
          {:ok, _} ->
            {:noreply,
             socket
             |> push_undo(
               {:restore, placement.session_id, placement.room_id, placement.day, placement.slot,
                placement.locked, placement.week_mask}
             )
             |> load_board()
             |> select_session(session_id)}

          {:error, reason} ->
            {:noreply, Errors.put(socket, reason)}
        end
    end
  end

  # Undo uses context operations to restore the previous placement state.
  defp undo_entry(nil, placement), do: {:remove, placement.session_id}

  defp undo_entry(existing, _placement),
    do:
      {:restore, existing.session_id, existing.room_id, existing.day, existing.slot,
       existing.locked, existing.week_mask}

  defp push_undo(socket, entry), do: update(socket, :undo, &[entry | &1])

  defp undo(%{assigns: %{undo: []}} = socket), do: socket

  defp undo(%{assigns: %{undo: [entry | rest]}} = socket) do
    result =
      case entry do
        {:remove, session_id} ->
          case Enum.find(socket.assigns.board.placements, &(&1.session_id == session_id)) do
            nil -> {:ok, socket}
            placement -> placement |> Planning.delete_placement() |> after_undo(socket)
          end

        {:restore, session_id, room_id, day, slot, locked, weeks} ->
          attrs = %{
            "room_id" => room_id,
            "day" => day,
            "slot" => slot,
            "locked" => locked,
            "week_mask" => weeks
          }

          case Enum.find(socket.assigns.board.placements, &(&1.session_id == session_id)) do
            nil ->
              Planning.create_placement(
                Map.merge(attrs, %{
                  "plan_id" => socket.assigns.plan_id,
                  "session_id" => session_id
                })
              )
              |> after_undo(socket)

            placement ->
              placement |> Planning.update_placement(attrs) |> after_undo(socket)
          end
      end

    case result do
      {:ok, next} -> assign(next, :undo, rest)
      {:error, next} -> next
    end
  end

  defp after_undo({:ok, _record}, socket) do
    socket = socket |> load_board() |> select_session(socket.assigns.selected_session_id)

    socket =
      case {socket.assigns.selected_session, socket.assigns.selected_placement} do
        {%{automatic_weeks: true}, %{week_mask: [week]}} ->
          push_patch(socket, to: workspace_path(socket.assigns, %{"week" => week}))

        _ ->
          socket
      end

    {:ok, socket}
  end

  defp after_undo({:error, reason}, socket), do: {:error, Errors.put(socket, reason)}

  # State

  defp load_board(socket) do
    board = Planning.board_data(socket.assigns.plan_id)

    socket
    |> assign(:board, board)
    |> assign(:plan, board.plan)
    |> assign(:page_title, board.plan.name)
    |> assign(:report_cache, %{})
    |> assign(:busiest, busiest_week(board, socket.assigns.term))
    |> load_report()
  end

  defp select_session(socket, session_id) do
    board = socket.assigns.board
    placement = Enum.find(board.placements, &(&1.session_id == session_id))

    session =
      (placement && placement.session) ||
        Enum.find(board.unplaced, &(&1.id == session_id))

    session =
      if session && session.automatic_weeks do
        %{
          session
          | week_mask: if(placement, do: placement.week_mask, else: [socket.assigns.week])
        }
      else
        session
      end

    if session do
      socket
      |> assign(:selected_session_id, session_id)
      |> assign(:selected_placement, placement)
      |> assign(:selected_session, session)
      |> assign(:target, nil)
      |> assign(:assessment, [])
      |> assign_selection_details(session, placement)
    else
      clear_selection(socket)
    end
  end

  # Re-reads the selection from the freshly loaded board, so the inspector always
  # shows fully preloaded associations.
  defp reselect(socket, session_id), do: select_session(socket, session_id)

  defp clear_selection(socket) do
    socket
    |> assign(:selected_session_id, nil)
    |> assign(:selected_placement, nil)
    |> assign(:selected_session, nil)
    |> assign(:target, nil)
    |> assign(:assessment, [])
    |> assign(:explanation, nil)
    |> assign(:legal, %{})
  end

  # Select the first allowed room. If none exists, let the context explain the refusal.
  defp first_free_room(_socket, nil, _day, _slot), do: nil

  defp first_free_room(socket, session, day, slot) do
    session
    |> Feasibility.cells_for(socket.assigns.plan_id)
    |> Map.get({day, slot}, [])
    |> List.first()
  end

  defp assign_selection_details(socket, session, placement) do
    legal = Feasibility.cells_for(session, socket.assigns.plan_id)

    socket
    |> assign(:legal, legal)
    |> assign(:explanation, Feasibility.explain_session(session, placement, legal))
  end

  defp load_report(socket) do
    tab = socket.assigns.tab
    cache = socket.assigns.report_cache

    value =
      Map.get_lazy(cache, tab, fn ->
        case tab do
          "quality" -> Quality.report(socket.assigns.plan_id)
          "coverage" -> Curriculum.plan_coverage(socket.assigns.plan_id)
          _ -> nil
        end
      end)

    socket
    |> assign(:report_cache, Map.put(cache, tab, value))
    |> assign(:quality, if(tab == "quality", do: value))
    |> assign(:coverage, if(tab == "coverage", do: value, else: []))
  end

  # Render

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:workspace, Workspace.location(assigns))
      |> assign(
        :solver_blocked,
        Enum.any?(assigns.board.checks, &(not String.starts_with?(&1.type, "external_")))
      )
      |> assign(:solver_limit, NeuZeit.Config.load!().solver.time_limit)

    ~H"""
    <Layouts.app
      flash={@flash}
      nav={Nav.sections(@term)}
      current_path={~p"/terms/#{@term}/plans"}
      terms={@terms}
      current_term={@term}
      page_path={workspace_path(assigns)}
    >
      <.page_header title={@plan.name} subtitle={gate_summary(@board)}>
        <:status><.status_indicator status={@plan.status} /></:status>
        <:actions>
          <.link
            :if={@plan.status == "draft"}
            navigate={~p"/terms/#{@term}?plan_id=#{@plan.id}"}
            class="btn"
          >{gettext("Preparation")}</.link>
          <button
            :if={@plan.status == "draft"}
            class="btn btn-neutral"
            phx-click="undo"
            disabled={@plan.status != "draft" or @undo == []}
          >
            <.icon name="hero-arrow-uturn-left" class="size-4" /> {gettext("Undo last edit")}
          </button>
          <button
            :if={@plan.status == "draft"}
            id="publish-button"
            class="btn btn-neutral"
            phx-click="publish_open"
          >
            <.icon name="hero-paper-airplane" class="size-4" /> {gettext("Publish plan")}
          </button>
          <button class="btn btn-neutral" phx-click="refresh_board">{gettext("Refresh")}</button>
        </:actions>
      </.page_header>

      <div :if={@plan.status != "draft"} class="alert mb-4">
        <span>{gettext(
          "To change one date, open the calendar. To change the weekly timetable, create a draft."
        )}</span>
        <button class="btn btn-neutral" phx-click="clone_draft">{gettext("Copy to draft")}</button>
        <.link navigate={~p"/terms/#{@term}/calendar?plan_id=#{@plan.id}"} class="btn btn-neutral">{gettext(
          "Calendar by date"
        )}</.link>
      </div>
      <RunStatus.run_status
        board={@board}
        term={@term}
        workspace={@workspace}
        solving_since={@solving_since}
        tick={@tick}
        solver_limit={@solver_limit}
        solver_blocked={@solver_blocked && @plan.status == "draft"}
        last_result={@last_result}
      />

      <.tabs
        active={workspace_path(assigns)}
        items={[
          %{label: gettext("Semester template"), path: workspace_path(assigns, %{"tab" => "board"})},
          %{
            label: gettext("Checks"),
            path: workspace_path(assigns, %{"tab" => "checks"}),
            badge: length(@board.checks)
          },
          %{
            label: gettext("Warnings"),
            path: workspace_path(assigns, %{"tab" => "advisories"}),
            badge: length(@board.advisories)
          },
          %{label: gettext("Quality"), path: workspace_path(assigns, %{"tab" => "quality"})},
          %{label: gettext("Teaching hours"), path: workspace_path(assigns, %{"tab" => "coverage"})}
        ]}
      />

      <Reports.reports
        :if={@tab != "board"}
        tab={@tab}
        board={@board}
        plan={@plan}
        term={@term}
        workspace={@workspace}
        quality={@quality}
        coverage={@coverage}
      />

      <BoardEditor.board
        :if={@tab == "board"}
        board={@board}
        plan={@plan}
        term={@term}
        workspace={@workspace}
        week={@week}
        busiest={@busiest}
        lens={@lens}
        resource_id={@resource_id}
        search={@search}
        tray_limit={@tray_limit}
        selected_session_id={@selected_session_id}
        selected_placement={@selected_placement}
        selected_session={@selected_session}
        grid={@grid}
        legal={@legal}
        target={@target}
        assessment={@assessment}
        explanation={@explanation}
        cohorts={@cohorts}
        teachers={@teachers}
        rooms={@rooms}
      />

      <Publication.confirmation
        :if={@publishing}
        gate={@gate}
        acknowledged={@acknowledged}
        advisory_count={length(@board.advisories)}
      />
    </Layouts.app>
    """
  end

  defp gate_summary(board) do
    gettext("Unplaced: %{unplaced}, Conflicts: %{conflicts}, Warnings: %{advisories}",
      unplaced: length(board.unplaced),
      conflicts: length(board.checks),
      advisories: length(board.advisories)
    )
  end
end
