defmodule NeuZeitWeb.PlanCompareLiveTest do
  use NeuZeitWeb.ConnCase, async: true

  alias NeuZeit.{Catalog, Planning}
  alias NeuZeitWeb.PlanLive.Compare

  # The original plan and its copy differ by three edits: one session moved,
  # one newly placed and one no longer placed. Two sessions keep their positions,
  # one of them unlocked in the copy, and one session is unplaced in both.
  setup do
    {:ok, term} =
      Catalog.create_term(%{
        "name" => "Wintersemester 2026/27",
        "starts_on" => "2026-09-07",
        "ends_on" => "2026-12-20"
      })

    {:ok, building} = Catalog.create_building(%{"name" => "Hauptgebäude"})
    rooms = for n <- 1..2, do: room(building, "10#{n}")
    {:ok, wi} = Catalog.create_cohort(%{"name" => "WI-1"})
    {:ok, it} = Catalog.create_cohort(%{"name" => "IT-1"})
    {:ok, anna} = Catalog.create_teacher(%{"name" => "Anna Weber"})
    {:ok, erik} = Catalog.create_teacher(%{"name" => "Erik Hoffmann"})
    {:ok, original} = Planning.create_plan(%{"term_id" => term.id, "name" => "Original"})

    ctx = %{term: term, rooms: rooms, original: original}

    sessions = %{
      moved: session(ctx, "INF110", anna, wi),
      kept: session(ctx, "INF120", anna, wi),
      placed: session(ctx, "DEU100", erik, it),
      unplaced: session(ctx, "PHY100", erik, it),
      never: session(ctx, "MAT100", erik, it),
      unlocked: session(ctx, "ENG100", erik, it)
    }

    [first_room, second_room] = rooms

    # Anna and WI-1 wait one time slot on Monday in the original.
    place(original, sessions.moved, first_room, 1, 1)
    place(original, sessions.kept, first_room, 1, 3)
    place(original, sessions.unplaced, second_room, 4, 2)
    place(original, sessions.unlocked, first_room, 5, 1, %{"locked" => true})

    {:ok, copy} = Planning.clone_plan(original.id, %{"name" => "Fewer gaps"})
    copied = Map.new(Planning.list_placements(copy.id), &{&1.session_id, &1})

    {:ok, _} =
      Planning.update_placement(copied[sessions.moved.id], %{
        "slot" => 2,
        "room_id" => second_room.id
      })

    {:ok, _} = Planning.delete_placement(copied[sessions.unplaced.id])
    {:ok, _} = Planning.update_placement(copied[sessions.unlocked.id], %{"locked" => false})
    place(copy, sessions.placed, first_room, 3, 1)

    Map.merge(ctx, %{copy: copy, sessions: sessions, anna: anna, wi: wi, it: it})
  end

  defp room(building, name) do
    {:ok, room} = Catalog.create_room(%{"building_id" => building.id, "name" => name})
    room
  end

  defp session(ctx, code, teacher, cohort) do
    {:ok, course} = Catalog.create_course(%{"code" => code, "title" => code})

    {:ok, component} =
      Catalog.create_course_component(%{
        "course_id" => course.id,
        "kind" => "lecture",
        "allowed_room_ids" => Enum.map(ctx.rooms, & &1.id)
      })

    {:ok, session} =
      NeuZeit.Fixtures.create_session(%{
        "term_id" => ctx.term.id,
        "course_component_id" => component.id,
        "teacher_id" => teacher.id,
        "week_mask" => Enum.to_list(1..ctx.term.weeks_count),
        "duration_slots" => 1,
        "cohort_ids" => [cohort.id]
      })

    session
  end

  defp place(plan, session, room, day, slot, attrs \\ %{}) do
    {:ok, placement} =
      Planning.create_placement(
        Map.merge(
          %{
            "plan_id" => plan.id,
            "session_id" => session.id,
            "room_id" => room.id,
            "day" => day,
            "slot" => slot
          },
          attrs
        )
      )

    placement
  end

  defp compare(conn, ctx, params \\ []) do
    {:ok, live, _html} =
      live(
        conn,
        ~p"/terms/#{ctx.term}/plans/compare?#{[before: ctx.original.id, after: ctx.copy.id] ++ params}"
      )

    live
  end

  defp change(kind, session),
    do: "#compare-changes [data-change='#{kind}'][data-session-id='#{session.id}']"

  describe "changed sessions" do
    test "lists exactly the moved, newly placed and no longer placed sessions",
         %{conn: conn} = ctx do
      live = compare(conn, ctx)

      assert has_element?(live, "#compare-changes [data-session-id]", "INF110")
      assert has_element?(live, change(:moved, ctx.sessions.moved))
      assert has_element?(live, change(:placed, ctx.sessions.placed))
      assert has_element?(live, change(:unplaced, ctx.sessions.unplaced))

      # Unchanged positions, a lock change and a session unplaced in both are not changes.
      for key <- [:kept, :never, :unlocked] do
        refute has_element?(live, "#compare-changes [data-session-id='#{ctx.sessions[key].id}']")
      end

      assert has_element?(live, "p", "Moved: 1, Newly placed: 1, No longer placed: 1")
    end

    test "shows the old and new day, time, room and weeks of a moved session",
         %{conn: conn} = ctx do
      live = compare(conn, ctx)
      row = change(:moved, ctx.sessions.moved)

      assert has_element?(live, "#{row} td:nth-child(2)", "Mon 08:00-09:30")
      assert has_element?(live, "#{row} td:nth-child(2)", "101")
      assert has_element?(live, "#{row} td:nth-child(3)", "Mon 09:50-11:20")
      assert has_element?(live, "#{row} td:nth-child(3)", "102")
      assert has_element?(live, "#{row} td:nth-child(3)", "Every week")
    end

    test "names the plan side where a session is not placed", %{conn: conn} = ctx do
      live = compare(conn, ctx)

      assert has_element?(
               live,
               "#{change(:placed, ctx.sessions.placed)} td:nth-child(2)",
               "Not placed"
             )

      assert has_element?(
               live,
               "#{change(:placed, ctx.sessions.placed)} td:nth-child(3)",
               "Wed 08:00-09:30"
             )

      assert has_element?(
               live,
               "#{change(:unplaced, ctx.sessions.unplaced)} td:nth-child(2)",
               "Thu 09:50-11:20"
             )

      assert has_element?(
               live,
               "#{change(:unplaced, ctx.sessions.unplaced)} td:nth-child(3)",
               "Not placed"
             )
    end

    test "each side links to the session on that plan's board", %{conn: conn} = ctx do
      live = compare(conn, ctx)
      moved = ctx.sessions.moved

      for {plan, column} <- [{ctx.original, 2}, {ctx.copy, 3}] do
        board = ~p"/terms/#{ctx.term}/plans/#{plan}?#{[tab: "board", week: 1, session: moved.id]}"

        assert has_element?(
                 live,
                 ~s{#{change(:moved, moved)} td:nth-child(#{column}) a[href="#{board}"]}
               )
      end

      {:ok, board, _html} =
        live
        |> element("#{change(:unplaced, ctx.sessions.unplaced)} td:nth-child(3) a")
        |> render_click()
        |> follow_redirect(conn)

      # The copy no longer places it, so the board selects it in the tray.
      assert has_element?(
               board,
               "#board-tray-session-#{ctx.sessions.unplaced.id}[aria-pressed='true']"
             )
    end

    test "groups changes by teacher or by group", %{conn: conn} = ctx do
      live = compare(conn, ctx)

      assert has_element?(live, "#compare-group-#{ctx.anna.id} th", "Anna Weber")

      assert has_element?(
               live,
               "#compare-group-#{ctx.anna.id} [data-session-id='#{ctx.sessions.moved.id}']"
             )

      live |> form("#compare-grouping", by: "group") |> render_change()

      assert_patch(
        live,
        ~p"/terms/#{ctx.term}/plans/compare?#{[before: ctx.original.id, after: ctx.copy.id, by: "group"]}"
      )

      assert has_element?(
               live,
               "#compare-group-#{ctx.wi.id} [data-session-id='#{ctx.sessions.moved.id}']"
             )

      assert has_element?(
               live,
               "#compare-group-#{ctx.it.id} [data-session-id='#{ctx.sessions.placed.id}']"
             )

      assert has_element?(
               live,
               "#compare-group-#{ctx.it.id} [data-session-id='#{ctx.sessions.unplaced.id}']"
             )

      refute has_element?(live, "#compare-group-#{ctx.anna.id}")
    end

    test "swapping the plans reverses the changes", %{conn: conn} = ctx do
      live = compare(conn, ctx)

      live |> element("#compare-swap") |> render_click()

      assert has_element?(live, change(:moved, ctx.sessions.moved))
      assert has_element?(live, change(:unplaced, ctx.sessions.placed))
      assert has_element?(live, change(:placed, ctx.sessions.unplaced))
    end

    test "comparing a plan with an unchanged copy finds no differences", %{conn: conn} = ctx do
      {:ok, same} = Planning.clone_plan(ctx.original.id)

      {:ok, live, _html} =
        live(
          conn,
          ~p"/terms/#{ctx.term}/plans/compare?#{[before: ctx.original.id, after: same.id]}"
        )

      assert has_element?(live, "p", "No placement differences")
      refute has_element?(live, "#compare-changes")
    end
  end

  describe "quality" do
    test "shows both plans side by side with the change", %{conn: conn} = ctx do
      live = compare(conn, ctx)
      weeks = ctx.term.weeks_count

      # Anna and WI-1 each lose one gap per teaching week.
      assert has_element?(live, "#compare-total-gaps td:nth-child(2)", "#{2 * weeks}")
      assert has_element?(live, "#compare-total-gaps td:nth-child(3)", "0")
      assert has_element?(live, "#compare-total-gaps td:nth-child(4)", "-#{2 * weeks}")

      # Each plan leaves two sessions unplaced, but not the same two.
      assert has_element?(live, "#compare-total-unplaced td:nth-child(2)", "2")
      assert has_element?(live, "#compare-total-unplaced td:nth-child(3)", "2")
      assert has_element?(live, "#compare-total-checks td:nth-child(4)", "0")
      assert has_element?(live, "#compare-total-warnings td:nth-child(4)", "0")
    end

    test "each teacher shows the quality change of their sessions", %{conn: conn} = ctx do
      live = compare(conn, ctx)

      assert has_element?(
               live,
               "#compare-group-#{ctx.anna.id} th",
               "Gaps: -#{ctx.term.weeks_count}"
             )
    end
  end

  describe "choosing plans" do
    test "the selects compare other plans", %{conn: conn} = ctx do
      live = compare(conn, ctx)

      live
      |> form("#compare-plans", before: ctx.copy.id, after: ctx.original.id)
      |> render_change()

      assert_patch(
        live,
        ~p"/terms/#{ctx.term}/plans/compare?#{[before: ctx.copy.id, after: ctx.original.id, by: "teacher"]}"
      )

      assert has_element?(live, change(:placed, ctx.sessions.unplaced))
    end

    test "a plan of another term is not found", %{conn: conn} = ctx do
      {:ok, other_term} =
        Catalog.create_term(%{
          "name" => "Sommersemester 2027",
          "starts_on" => "2027-03-01",
          "ends_on" => "2027-06-30"
        })

      {:ok, foreign} = Planning.create_plan(%{"term_id" => other_term.id, "name" => "Foreign"})

      assert_raise Ecto.NoResultsError, fn ->
        live(
          conn,
          ~p"/terms/#{ctx.term}/plans/compare?#{[before: ctx.original.id, after: foreign.id]}"
        )
      end
    end

    test "a term with one plan offers to copy it", %{conn: conn} do
      term = NeuZeit.Fixtures.term_fixture()
      {:ok, _plan} = Planning.create_plan(%{"term_id" => term.id, "name" => "Only"})

      {:ok, live, _html} = live(conn, ~p"/terms/#{term}/plans/compare")

      assert has_element?(live, "p", "No second plan to compare")
    end

    test "the plans list compares the two ticked plans, the active one first",
         %{conn: conn} = ctx do
      {:ok, _} = Planning.publish_plan(ctx.original.id, allow_partial: true)
      {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/plans")

      assert has_element?(live, "#compare-button[disabled]")

      live |> element("#compare-#{ctx.copy.id}") |> render_click()
      live |> element("#compare-#{ctx.original.id}") |> render_click()
      refute has_element?(live, "#compare-button[disabled]")

      live |> element("#compare-button") |> render_click()

      assert_redirect(live, Compare.path(ctx.term, ctx.original, ctx.copy))
    end

    test "a third ticked plan replaces the first", %{conn: conn} = ctx do
      {:ok, third} = Planning.clone_plan(ctx.copy.id)
      {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/plans")

      for plan <- [ctx.original, ctx.copy, third] do
        live |> element("#compare-#{plan.id}") |> render_click()
      end

      refute has_element?(live, "#compare-#{ctx.original.id}[checked]")
      live |> element("#compare-button") |> render_click()

      assert_redirect(live, Compare.path(ctx.term, ctx.copy, third))
    end

    test "a draft compares itself with the active plan", %{conn: conn} = ctx do
      {:ok, _} = Planning.publish_plan(ctx.original.id, allow_partial: true)

      {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/plans/#{ctx.copy}")

      assert has_element?(
               live,
               ~s{#compare-active[href="#{Compare.path(ctx.term, ctx.original, ctx.copy)}"]}
             )

      {:ok, active, _html} = live(conn, ~p"/terms/#{ctx.term}/plans/#{ctx.original}")
      refute has_element?(active, "#compare-active")
    end

    test "without an active plan a draft offers no comparison", %{conn: conn} = ctx do
      {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/plans/#{ctx.copy}")

      refute has_element?(live, "#compare-active")
    end
  end
end
