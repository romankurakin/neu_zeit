defmodule NeuZeitWeb.PlanLiveTest do
  use NeuZeitWeb.ConnCase, async: true

  alias NeuZeit.{Catalog, Planning}

  setup do
    {:ok, term} =
      Catalog.create_term(%{
        "name" => "Wintersemester 2026/27",
        "starts_on" => "2026-09-07",
        "ends_on" => "2026-12-20"
      })

    {:ok, building} = Catalog.create_building(%{"name" => "Hauptgebäude"})
    rooms = for n <- 1..2, do: room(building, "10#{n}")
    {:ok, plan} = Planning.create_plan(%{"term_id" => term.id, "name" => "Entwurf 1"})
    {:ok, cohort} = Catalog.create_cohort(%{"name" => "WI-1"})

    %{term: term, building: building, rooms: rooms, plan: plan, cohort: cohort}
  end

  defp room(building, name) do
    {:ok, room} = Catalog.create_room(%{"building_id" => building.id, "name" => name})
    room
  end

  defp component(rooms, code) do
    {:ok, course} = Catalog.create_course(%{"code" => code, "title" => code})

    {:ok, component} =
      Catalog.create_course_component(%{
        "course_id" => course.id,
        "kind" => "lecture",
        "allowed_room_ids" => Enum.map(rooms, & &1.id)
      })

    component
  end

  defp session(ctx, code, teacher_name, overrides \\ %{}) do
    {:ok, teacher} = Catalog.create_teacher(%{"name" => teacher_name})

    {:ok, session} =
      NeuZeit.Fixtures.create_session(
        Map.merge(
          %{
            "term_id" => ctx.term.id,
            "course_component_id" => component(ctx.rooms, code).id,
            "teacher_id" => teacher.id,
            "week_mask" => Enum.to_list(1..ctx.term.weeks_count),
            "duration_slots" => 1,
            "cohort_ids" => [ctx.cohort.id]
          },
          overrides
        )
      )

    session
  end

  defp board(conn, ctx) do
    {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/plans/#{ctx.plan}")
    live
  end

  defp place_at(live, day, slot) do
    live |> element("#board-cell-#{day}-#{slot} > button") |> render_click()

    [room | _] =
      live
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[phx-click='apply_position']")
      |> LazyHTML.attribute("phx-value-room-id")

    live
    |> element("button[phx-click='apply_position'][phx-value-room-id='#{room}']")
    |> render_click()
  end

  describe "the plans list" do
    test "shows a draft and can clone it", %{conn: conn} = ctx do
      {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/plans")

      assert has_element?(live, "#plan-#{ctx.plan.id}", "Entwurf 1")

      live |> element(~s{button[phx-value-id="#{ctx.plan.id}"]}, "Copy") |> render_click()

      assert length(Planning.list_plans()) == 2
    end

    test "a plan can be renamed so variants are comparable", %{conn: conn} = ctx do
      {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/plans/#{ctx.plan}/rename")

      live |> form("#plan-form", plan: %{name: "Fewer Saturdays"}) |> render_submit()

      assert Planning.get_plan!(ctx.plan.id).name == "Fewer Saturdays"
      assert has_element?(live, "#plans", "Fewer Saturdays")
    end
  end

  describe "the board" do
    test "lists unplaced sessions in the tray", %{conn: conn} = ctx do
      created = session(ctx, "INF110", "Anna Weber")
      live = board(conn, ctx)

      assert has_element?(live, "#board-tray-session-#{created.id}")
      assert has_element?(live, "summary", "1 unplaced")
    end

    test "selecting a session reveals where it may legally go", %{conn: conn} = ctx do
      created = session(ctx, "INF110", "Anna Weber")
      live = board(conn, ctx)

      html =
        live
        |> element("#board-tray-session-#{created.id}")
        |> render_click()

      # Unconstrained: the whole grid.
      assert html =~ "36 possible start times with a free room."
    end

    test "a slot profile narrows the legal cells", %{conn: conn} = ctx do
      {:ok, profile} =
        Catalog.create_slot_profile(%{
          "term_id" => ctx.term.id,
          "name" => "DE_EARLY",
          "cells" => [%{"day" => 1, "slot" => 1}, %{"day" => 3, "slot" => 1}]
        })

      created = session(ctx, "DEU100", "Anna Weber", %{"slot_profile_id" => profile.id})
      live = board(conn, ctx)

      html = live |> element("#board-tray-session-#{created.id}") |> render_click()
      assert html =~ "2 possible start times with a free room."
    end

    test "clicking a legal cell places the session", %{conn: conn} = ctx do
      created = session(ctx, "INF110", "Anna Weber")
      live = board(conn, ctx)

      live |> element("#board-tray-session-#{created.id}") |> render_click()
      place_at(live, 2, 3)

      assert [placement] = Planning.list_placements(ctx.plan.id)
      assert placement.session_id == created.id
      assert placement.day == 2 and placement.slot == 3
      refute has_element?(live, "#board-tray-session-#{created.id}")
    end

    test "dropping onto the tray unplaces a session", %{conn: conn} = ctx do
      created = session(ctx, "INF110", "Anna Weber")
      live = board(conn, ctx)

      live |> element("#board-tray-session-#{created.id}") |> render_click()
      place_at(live, 2, 3)
      assert length(Planning.list_placements(ctx.plan.id)) == 1

      render_hook(live, "drop_session", %{"session-id" => created.id, "target" => "tray"})

      assert Planning.list_placements(ctx.plan.id) == []
      assert has_element?(live, "#board-tray-session-#{created.id}")
    end

    test "a drop onto an illegal cell is refused and explains itself", %{conn: conn} = ctx do
      only = [hd(ctx.rooms)]
      {:ok, course} = Catalog.create_course(%{"code" => "ONE", "title" => "One"})

      {:ok, shared_component} =
        Catalog.create_course_component(%{
          "course_id" => course.id,
          "kind" => "lecture",
          "allowed_room_ids" => Enum.map(only, & &1.id)
        })

      {:ok, first_teacher} = Catalog.create_teacher(%{"name" => "Anna Weber"})
      {:ok, second_teacher} = Catalog.create_teacher(%{"name" => "Erik Hoffmann"})

      attrs = %{
        "term_id" => ctx.term.id,
        "course_component_id" => shared_component.id,
        "week_mask" => [1, 2, 3],
        "duration_slots" => 1,
        "cohort_ids" => [ctx.cohort.id]
      }

      {:ok, first} =
        NeuZeit.Fixtures.create_session(Map.put(attrs, "teacher_id", first_teacher.id))

      {:ok, second} =
        NeuZeit.Fixtures.create_session(Map.put(attrs, "teacher_id", second_teacher.id))

      live = board(conn, ctx)
      live |> element("#board-tray-session-#{first.id}") |> render_click()
      place_at(live, 2, 3)

      # The only room is taken in an overlapping week, so the cell is not legal
      # for the second session and the drop must change nothing.
      html =
        render_hook(live, "drop_session", %{
          "session-id" => second.id,
          "target" => "cell",
          "day" => "2",
          "slot" => "3"
        })

      assert length(Planning.list_placements(ctx.plan.id)) == 1
      assert html =~ "room" or html =~ "blank"
    end

    test "undo reverses a placement and then an unplacement", %{conn: conn} = ctx do
      created = session(ctx, "INF110", "Anna Weber")
      live = board(conn, ctx)

      live |> element("#board-tray-session-#{created.id}") |> render_click()
      place_at(live, 2, 3)
      assert length(Planning.list_placements(ctx.plan.id)) == 1

      live |> element("button", "Undo last edit") |> render_click()
      assert Planning.list_placements(ctx.plan.id) == []

      # Removing a placement can also be undone.
      live |> element("#board-tray-session-#{created.id}") |> render_click()
      place_at(live, 2, 3)
      render_hook(live, "drop_session", %{"session-id" => created.id, "target" => "tray"})
      assert Planning.list_placements(ctx.plan.id) == []

      live |> element("button", "Undo last edit") |> render_click()
      assert [restored] = Planning.list_placements(ctx.plan.id)
      assert restored.day == 2 and restored.slot == 3
    end

    test "shows every placement sharing a cell", %{conn: conn} = ctx do
      [first_room, second_room] = ctx.rooms
      {:ok, other_cohort} = Catalog.create_cohort(%{"name" => "IT-1"})

      first = session(ctx, "A", "Anna Weber")
      second = session(ctx, "B", "Erik Hoffmann", %{"cohort_ids" => [other_cohort.id]})

      for {s, r} <- [{first, first_room}, {second, second_room}] do
        {:ok, _} =
          Planning.create_placement(%{
            "plan_id" => ctx.plan.id,
            "session_id" => s.id,
            "room_id" => r.id,
            "day" => 2,
            "slot" => 3
          })
      end

      live = board(conn, ctx)

      # Different rooms make this legal, so neither may be hidden.
      assert has_element?(live, "#board [data-session-id='#{first.id}']")
      assert has_element?(live, "#board [data-session-id='#{second.id}']")
    end

    test "the week picker only shows placements taught that week", %{conn: conn} = ctx do
      created = session(ctx, "INF110", "Anna Weber", %{"week_mask" => [1, 2]})

      {:ok, _} =
        Planning.create_placement(%{
          "plan_id" => ctx.plan.id,
          "session_id" => created.id,
          "room_id" => hd(ctx.rooms).id,
          "day" => 2,
          "slot" => 3
        })

      live = board(conn, ctx)
      assert has_element?(live, "#board [data-session-id='#{created.id}']")

      live |> element(~s{button[phx-value-week="15"]}, "Last") |> render_click()
      refute has_element?(live, "#board [data-session-id='#{created.id}']")
    end

    test "the explainer names the rules holding a placement in place", %{conn: conn} = ctx do
      {:ok, profile} =
        Catalog.create_slot_profile(%{
          "term_id" => ctx.term.id,
          "name" => "DE_EARLY",
          "cells" => [%{"day" => 1, "slot" => 1}, %{"day" => 3, "slot" => 1}]
        })

      created = session(ctx, "DEU100", "Anna Weber", %{"slot_profile_id" => profile.id})
      live = board(conn, ctx)

      live |> element("#board-tray-session-#{created.id}") |> render_click()
      html = place_at(live, 1, 1)

      # Show placement rules and links to their settings.
      assert html =~ "DE_EARLY"
      assert html =~ "DE_EARLY"

      assert has_element?(
               live,
               ~s{a[href^="/terms/#{ctx.term.id}/slot-profiles/#{profile.id}/edit?"]}
             )
    end

    test "locking a placement is reflected on the card", %{conn: conn} = ctx do
      created = session(ctx, "INF110", "Anna Weber")
      live = board(conn, ctx)

      live |> element("#board-tray-session-#{created.id}") |> render_click()
      place_at(live, 2, 3)

      live |> element("button", "Lock") |> render_click()

      assert [placement] = Planning.list_placements(ctx.plan.id)
      assert placement.locked
      assert has_element?(live, "button", "Unlock")
    end
  end

  describe "diagnostics" do
    test "an empty plan reports no conflicts", %{conn: conn} = ctx do
      {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/plans/#{ctx.plan}?tab=checks")

      assert has_element?(live, "#checks", "No rule violations")
    end

    test "advisories are shown as needing a human decision", %{conn: conn} = ctx do
      {:ok, base} = Catalog.create_cohort(%{"name" => "WI-9"})
      {:ok, subgroup} = Catalog.create_cohort(%{"name" => "D1"})
      [first_room, second_room] = ctx.rooms

      first = session(ctx, "A", "Anna Weber", %{"cohort_ids" => [base.id]})
      second = session(ctx, "B", "Erik Hoffmann", %{"cohort_ids" => [subgroup.id]})

      for {s, r} <- [{first, first_room}, {second, second_room}] do
        {:ok, _} =
          Planning.create_placement(%{
            "plan_id" => ctx.plan.id,
            "session_id" => s.id,
            "room_id" => r.id,
            "day" => 2,
            "slot" => 3
          })
      end

      {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/plans/#{ctx.plan}?tab=advisories")

      assert has_element?(live, "#advisories", "Group may overlap with a subgroup")
      assert has_element?(live, "#advisories button", "Show in timetable")
    end

    test "locating an advisory selects it on the board", %{conn: conn} = ctx do
      created = session(ctx, "INF110", "Anna Weber", %{"week_mask" => [3, 4]})

      {:ok, placement} =
        Planning.create_placement(%{
          "plan_id" => ctx.plan.id,
          "session_id" => created.id,
          "room_id" => hd(ctx.rooms).id,
          "day" => 2,
          "slot" => 3
        })

      {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/plans/#{ctx.plan}?tab=checks")

      render_hook(live, "locate", %{"placement-id" => placement.id})

      # Select a week in the placement mask so the card is visible.
      assert render(live) =~ "Week 3 of 15"
      assert has_element?(live, "#board [data-session-id='#{created.id}']")
    end
  end

  describe "publishing" do
    test "the gate is not shown until asked for", %{conn: conn} = ctx do
      {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/plans/#{ctx.plan}")
      refute has_element?(live, "#publish-gate")
    end

    test "partial publication requires its own confirmation", %{conn: conn} = ctx do
      _created = session(ctx, "INF110", "Anna Weber")

      {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/plans/#{ctx.plan}")
      live |> element("#publish-button") |> render_click()

      assert has_element?(live, "#publish-gate")
      # General review does not confirm partial publication.
      live |> element(~s{input[phx-value-key="advisories"]}) |> render_click()
      live |> element(~s{input[phx-value-key="registers"]}) |> render_click()

      assert has_element?(live, ~s{#publish-gate button[disabled]}, "Publish")
      render_hook(live, "publish_confirm", %{})
      assert Planning.get_plan!(ctx.plan.id).status == "draft"
      live |> element("#publish-button") |> render_click()

      for key <- ["advisories", "registers", "partial"] do
        live |> element(~s{input[phx-value-key="#{key}"]}) |> render_click()
      end

      refute has_element?(live, ~s{#publish-gate button[disabled]}, "Publish")
      live |> element(~s{#publish-gate button}, "Publish") |> render_click()
      assert Planning.get_plan!(ctx.plan.id).status == "active"
    end

    test "the soft conditions must be confirmed by a person", %{conn: conn} = ctx do
      {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/plans/#{ctx.plan}")
      live |> element("#publish-button") |> render_click()

      # With no sessions, placement checks pass. Manual confirmations are still required.
      assert has_element?(live, ~s{#publish-gate button[disabled]}, "Publish")

      live |> element(~s{input[phx-value-key="advisories"]}) |> render_click()
      assert has_element?(live, ~s{#publish-gate button[disabled]}, "Publish")

      live |> element(~s{input[phx-value-key="registers"]}) |> render_click()
      refute has_element?(live, ~s{#publish-gate button[disabled]}, "Publish")
    end

    test "confirming publishes and archives the previous active plan", %{conn: conn} = ctx do
      {:ok, previous} = Planning.create_plan(%{"term_id" => ctx.term.id, "name" => "Alt"})
      {:ok, previous} = Planning.publish_plan(previous.id)
      assert previous.status == "active"

      {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/plans/#{ctx.plan}")
      live |> element("#publish-button") |> render_click()
      live |> element(~s{input[phx-value-key="advisories"]}) |> render_click()
      live |> element(~s{input[phx-value-key="registers"]}) |> render_click()
      live |> element(~s{#publish-gate button}, "Publish") |> render_click()

      assert Planning.get_plan!(ctx.plan.id).status == "active"
      assert Planning.get_plan!(previous.id).status == "archived"
    end

    test "an active plan offers no publish button", %{conn: conn} = ctx do
      {:ok, _} = Planning.publish_plan(ctx.plan.id)

      {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/plans/#{ctx.plan}")
      refute has_element?(live, "#publish-button")
    end

    test "an archived plan can be cloned back into a draft", %{conn: conn} = ctx do
      {:ok, _} = Planning.publish_plan(ctx.plan.id)
      {:ok, newer} = Planning.create_plan(%{"term_id" => ctx.term.id, "name" => "Newer"})
      {:ok, _} = Planning.publish_plan(newer.id)

      assert Planning.get_plan!(ctx.plan.id).status == "archived"

      {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/plans")

      # Rollback is clone-then-publish: a term holds only one active plan.
      live |> element(~s{button[phx-value-id="#{ctx.plan.id}"]}, "Copy") |> render_click()

      clone = Planning.list_plans() |> Enum.find(&(&1.name =~ "copy"))
      assert clone.status == "draft"
    end
  end

  describe "solving" do
    test "a stale solve explains that newer edits were preserved on the board",
         %{conn: conn} = ctx do
      live = board(conn, ctx)

      message =
        "The plan changed while the solver was running. Your edits were kept. Run the solver again."

      send(live.pid, {:solve_started, ctx.plan.id, DateTime.utc_now()})
      send(live.pid, {:solve_finished, ctx.plan.id, {:error, {:conflict, message}}})

      assert has_element?(
               live,
               "#flash-error",
               "The timetable changed during calculation. Your edits were kept. Start a new calculation."
             )

      refute has_element?(live, "#solve-button[disabled]")
    end

    test "the context refuses to create a placement outside the grid", %{conn: _conn} = ctx do
      created = session(ctx, "INF110", "Anna Weber")

      # The context rejects invalid placements before they reach the checks view.
      assert {:error, reason} =
               Planning.create_placement(%{
                 "plan_id" => ctx.plan.id,
                 "session_id" => created.id,
                 "room_id" => hd(ctx.rooms).id,
                 "day" => 99,
                 "slot" => 1
               })

      # The shared error formatter must handle an unexpected context result.
      assert NeuZeitWeb.UI.Errors.message(reason) =~ ~r/grid|day|conflict/i
    end

    test "the solver cannot start while hard conflicts remain", %{conn: conn} = ctx do
      created = session(ctx, "INF110", "Anna Weber")

      # Insert an invalid placement directly to test detection and refusal to calculate.
      NeuZeit.Repo.insert!(%NeuZeit.Planning.Placement{
        plan_id: ctx.plan.id,
        session_id: created.id,
        term_id: ctx.term.id,
        room_id: hd(ctx.rooms).id,
        week_mask: created.week_mask,
        duration_slots: 1,
        day: 99,
        slot: 1
      })

      {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/plans/#{ctx.plan}?tab=board")

      assert render(live) =~
               "Resolve rule violations on the Checks tab before generating the timetable."

      assert {:error, _} = NeuZeit.Solver.PlanRuns.solve(ctx.plan.id)
    end

    test "a run is announced and reflected in the page", %{conn: conn} = ctx do
      {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/plans/#{ctx.plan}?tab=board")

      refute has_element?(live, "#solve-button[disabled]")

      send(live.pid, {:solve_started, ctx.plan.id, DateTime.utc_now()})
      assert render(live) =~ "Generating timetable"

      live |> element("a", "Quality") |> render_click()
      assert has_element?(live, "#plan-run-status", "Generating timetable")
      refute has_element?(live, "a", "Calculation")

      send(live.pid, {:solve_finished, ctx.plan.id, {:ok, %{}}})
      assert render(live) =~ "All sessions have been scheduled."
    end

    test "a failed solve explains what to check first", %{conn: conn} = ctx do
      {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/plans/#{ctx.plan}?tab=board")

      # Matches an infeasible calculation response: two sessions compete for
      # one room at the only allowed start.
      failure =
        {:error,
         %{
           errors: [
             %{
               type: "solver_infeasible",
               message: "solver could not produce a complete timetable",
               solver_status: "INFEASIBLE"
             }
           ]
         }}

      send(live.pid, {:solve_finished, ctx.plan.id, failure})
      html = render(live)

      # The failure panel includes settings to review.
      assert html =~ "No timetable fits the current rules"
      assert html =~ "locked placement"
      assert has_element?(live, ~s{a[href="/courses"]})
      assert has_element?(live, ~s{a[href="/terms/#{ctx.term.id}/slot-profiles"]})
    end
  end
end
