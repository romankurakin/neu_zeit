defmodule NeuZeitWeb.WorkloadLiveTest do
  use NeuZeitWeb.ConnCase, async: false
  import NeuZeit.Fixtures
  alias NeuZeit.{Catalog, Planning}
  alias NeuZeit.Solver.PlanRuns

  setup do
    term = term_fixture(ends_on: ~D[2026-09-13])
    component = component_fixture()
    teacher = teacher_fixture()
    cohort = cohort_fixture()

    attrs = %{
      course_component_id: component.id,
      teacher_id: teacher.id,
      cohort_ids: [cohort.id],
      week_mask: [1, 2],
      duration_slots: 1,
      contact_hours: "4"
    }

    %{term: term, component: component, teacher: teacher, cohort: cohort, attrs: attrs}
  end

  test "one requirement creates multiple sessions and can be edited as a quantity",
       %{conn: conn} = ctx do
    {:ok, view, _} = live(conn, ~p"/terms/#{ctx.term}/workload/new")
    render_hook(view, "selection_changed", %{"selected" => [ctx.cohort.id]})

    view
    |> form("#workload-form",
      workload: %{
        course_component_id: ctx.component.id,
        teacher_id: ctx.teacher.id,
        contact_hours: "4",
        duration_slots: "1",
        slot_profile_id: ""
      }
    )
    |> render_submit()

    assert_patch(view, ~p"/terms/#{ctx.term}/workload")
    assert [%{count: 2} = row] = Catalog.list_workload(ctx.term.id)
    assert has_element?(view, "#workload-#{row.id}", ctx.teacher.name)
    view |> element("#workload-#{row.id} a", "Edit") |> render_click()
    view |> form("#workload-form", workload: %{contact_hours: "6"}) |> render_submit()
    assert [%{count: 3}] = Catalog.list_workload(ctx.term.id)
  end

  test "missing groups keep the form and show an error", %{conn: conn} = ctx do
    {:ok, view, _} = live(conn, ~p"/terms/#{ctx.term}/workload/new")

    view
    |> form("#workload-form",
      workload: %{
        course_component_id: ctx.component.id,
        teacher_id: ctx.teacher.id,
        contact_hours: "4",
        duration_slots: "1"
      }
    )
    |> render_submit()

    assert has_element?(view, "#workload-form fieldset p.text-error")
    assert Catalog.count_sessions(ctx.term.id) == 0
  end

  test "empty workload cannot start a calculation", %{conn: conn} = ctx do
    {:ok, view, _} = live(conn, ~p"/terms/#{ctx.term}")
    assert has_element?(view, "button[phx-click=generate][disabled]")
    render_hook(view, "generate", %{})
    assert Planning.list_plans(ctx.term.id) == []
  end

  test "generate creates a draft and schedules the load without manual placements",
       %{conn: conn} = ctx do
    {:ok, _} =
      Catalog.replace_teacher_availability(ctx.term.id, ctx.teacher.id, [
        %{day: 2, slot: 1},
        %{day: 2, slot: 2}
      ])

    profile =
      slot_profile_fixture(term: ctx.term, cells: [%{day: 2, slot: 1}, %{day: 2, slot: 2}])

    {:ok, :saved} =
      Catalog.save_workload(
        ctx.term.id,
        nil,
        Map.merge(ctx.attrs, %{
          slot_profile_id: profile.id,
          automatic_weeks: true,
          contact_hours: "4"
        })
      )

    existing = plan_fixture(term: ctx.term)
    {:ok, view, _} = live(conn, ~p"/terms/#{ctx.term}")
    view |> element("button[phx-click=generate]") |> render_click()
    plan = Enum.find(Planning.list_plans(ctx.term.id), &(&1.id != existing.id))
    assert_redirect(view, ~p"/terms/#{ctx.term}/plans/#{plan}")
    PlanRuns.subscribe(plan.id)

    result =
      PlanRuns.last_result(plan.id) ||
        receive do
          {:solve_finished, id, result} when id == plan.id -> result
        after
          30_000 -> flunk("workload calculation did not finish")
        end

    assert {:ok, _} = result
    placements = Planning.list_placements(plan.id)
    assert length(placements) == 2

    assert Enum.all?(
             placements,
             &(&1.day == 2 && &1.slot in [1, 2] &&
                 &1.room_id == hd(ctx.component.allowed_rooms).id)
           )

    assert Planning.list_placements(existing.id) == []
    assert Planning.get_plan!(plan.id).status == "draft"
    assert Planning.check_plan(plan.id) == []
  end

  test "undo restores the selected week of an automatically generated meeting",
       %{conn: conn} = ctx do
    attrs = Map.merge(ctx.attrs, %{automatic_weeks: true, contact_hours: "2"})
    {:ok, :saved} = Catalog.save_workload(ctx.term.id, nil, attrs)
    [row] = Catalog.list_workload(ctx.term.id)
    plan = plan_fixture(term: ctx.term)

    {:ok, _} =
      Planning.create_placement(%{
        plan_id: plan.id,
        session_id: hd(row.sessions).id,
        room_id: hd(ctx.component.allowed_rooms).id,
        day: 2,
        slot: 1,
        week_mask: [2]
      })

    {:ok, view, _} = live(conn, ~p"/terms/#{ctx.term}/plans/#{plan}?week=2")
    render_hook(view, "select_session", %{"session-id" => hd(row.sessions).id})
    view |> form("#placement-week", week: "1") |> render_change()
    assert [%{week_mask: [1]}] = Planning.list_placements(plan.id)
    view |> element("button", "Undo last edit") |> render_click()
    assert [%{week_mask: [2]}] = Planning.list_placements(plan.id)
    render_hook(view, "drop_session", %{"session-id" => hd(row.sessions).id, "target" => "tray"})
    assert Planning.list_placements(plan.id) == []
    view |> element("button", "Undo last edit") |> render_click()
    assert [%{week_mask: [2]}] = Planning.list_placements(plan.id)
  end

  test "only preparation starts calculation and checks the selected draft", %{conn: conn} = ctx do
    {:ok, :saved} = Catalog.save_workload(ctx.term.id, nil, ctx.attrs)
    plan = plan_fixture(term: ctx.term)
    other = plan_fixture(term: ctx.term)
    {:ok, view, _} = live(conn, ~p"/terms/#{ctx.term}/workload")
    refute has_element?(view, "button[phx-click=generate]")
    {:ok, view, _} = live(conn, ~p"/terms/#{ctx.term}/plans/#{plan}")
    refute has_element?(view, "#solve-button")
    assert has_element?(view, ~s(a[href="/terms/#{ctx.term.id}?plan_id=#{plan.id}"]))
    {:ok, view, _} = live(conn, ~p"/terms/#{ctx.term}?plan_id=#{plan.id}")
    assert has_element?(view, "button[phx-click=generate]")
    view |> form("#generation-plan", plan_id: other.id) |> render_change()
    assert has_element?(view, ~s(a[href="/terms/#{ctx.term.id}/plans/#{other.id}?tab=board"]))
  end
end
