defmodule NeuZeitWeb.WorkloadLiveTest do
  use NeuZeitWeb.ConnCase, async: false
  import NeuZeit.Fixtures
  alias NeuZeit.{Catalog, Planning, Repo}
  alias NeuZeit.Catalog.{Sessions, Workloads}
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

  test "one requirement creates recurring sessions and can be edited as a quantity",
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
    assert [row] = Catalog.list_workload(ctx.term.id)
    assert Workloads.series_count(row) == 1
    assert hd(row.sessions).week_mask == [1, 2]
    assert has_element?(view, "#workload-#{row.id}", ctx.teacher.name)
    view |> element("#workload-#{row.id} a", "Edit") |> render_click()
    view |> form("#workload-form", workload: %{contact_hours: "6"}) |> render_submit()
    assert [row] = Catalog.list_workload(ctx.term.id)
    assert Workloads.series_count(row) == 2
    assert Workloads.meeting_count(row) == 3
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
    assert length(placements) == 1
    assert hd(placements).week_mask == [1, 2]

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
    session_fixture(
      term: ctx.term,
      component: ctx.component,
      teacher: ctx.teacher,
      cohorts: [ctx.cohort],
      automatic_weeks: true,
      week_mask: [1, 2]
    )

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

  test "45 required hours show the rounded distribution and stay unchanged after saving",
       %{conn: conn} = ctx do
    term = term_fixture(ends_on: ~D[2026-12-13])
    {:ok, view, _} = live(conn, ~p"/terms/#{term}/workload/new")
    render_hook(view, "selection_changed", %{"selected" => [ctx.cohort.id]})

    view |> form("#workload-form", workload: form_attrs(ctx, "45")) |> render_change()

    assert has_element?(
             view,
             "#workload_duration_slots option[value='1']",
             "90 min, 2 academic hours"
           )

    assert has_element?(view, "#workload-preview-total", "23 sessions, 46 academic hours")
    assert has_element?(view, "#workload-hours-difference", "Required hours stay at 45")
    assert has_element?(view, "#workload-hours-difference", "Hours above the requirement: 1")
    assert has_element?(view, "#workload-preview-pattern", "Every week: 1 session")
    assert has_element?(view, "#workload-preview-pattern", "Odd weeks: 1 session")
    refute has_element?(view, "select#workload_remainder_parity")

    view |> form("#workload-form") |> render_submit()
    assert_patch(view, ~p"/terms/#{term}/workload")
    assert [row] = Catalog.list_workload(term.id)
    assert Decimal.equal?(row.requirement.contact_hours, 45)
    assert Workloads.meeting_count(row) == 23
    assert has_element?(view, "#workload-#{row.id}", "+1")
    assert has_element?(view, "#workload-#{row.id}", "Odd weeks: 1 session")

    view |> element("#workload-#{row.id} a", "Edit") |> render_click()
    assert has_element?(view, "#workload_contact_hours[value='45']")
    assert has_element?(view, "#workload-preview-total", "23 sessions, 46 academic hours")
  end

  test "choosing fewer sessions preserves the requirement and survives reopening",
       %{conn: conn} = ctx do
    term = term_fixture(ends_on: ~D[2026-12-13])
    {:ok, view, _} = live(conn, ~p"/terms/#{term}/workload/new")
    render_hook(view, "selection_changed", %{"selected" => [ctx.cohort.id]})
    view |> form("#workload-form", workload: form_attrs(ctx, "45")) |> render_change()
    view |> form("#workload-form", workload: %{rounding_mode: "down"}) |> render_change()

    assert has_element?(view, "#workload-preview-total", "22 sessions, 44 academic hours")
    assert has_element?(view, "#workload-hours-difference", "Hours below the requirement: 1")
    assert has_element?(view, "#workload-preview-pattern", "Even weeks: 1 session")

    view |> form("#workload-form") |> render_submit()
    assert [row] = Catalog.list_workload(term.id)
    assert Decimal.equal?(row.requirement.contact_hours, 45)
    assert row.requirement.rounding_mode == :down
    assert Workloads.meeting_count(row) == 22
    assert has_element?(view, "#workload-#{row.id}", "-1")

    view |> element("#workload-#{row.id} a", "Edit") |> render_click()
    assert has_element?(view, "#workload_rounding_mode option[value='down'][selected]")
    assert has_element?(view, "#workload-preview-total", "22 sessions, 44 academic hours")
    view |> form("#workload-form") |> render_submit()
    assert [saved] = Catalog.list_workload(term.id)
    assert Enum.map(saved.sessions, & &1.id) == Enum.map(row.sessions, & &1.id)
  end

  test "parity can be selected when either pattern preserves the hours", %{conn: conn} = ctx do
    term = term_fixture()
    {:ok, view, _} = live(conn, ~p"/terms/#{term}/workload/new")
    render_hook(view, "selection_changed", %{"selected" => [ctx.cohort.id]})
    view |> form("#workload-form", workload: form_attrs(ctx, "16")) |> render_change()

    assert has_element?(view, "select#workload_remainder_parity")
    refute has_element?(view, "select#workload_rounding_mode")
    refute has_element?(view, "#workload-hours-difference")
    view |> form("#workload-form", workload: %{remainder_parity: "even"}) |> render_change()
    assert has_element?(view, "#workload-preview-pattern", "Even weeks: 1 session")
    view |> form("#workload-form") |> render_submit()

    assert [row] = Catalog.list_workload(term.id)
    assert row.requirement.remainder_parity == :even
    assert hd(row.sessions).week_mask == Enum.to_list(2..16//2)
  end

  test "preview follows duration and available weeks and clears invalid input",
       %{conn: conn} = ctx do
    term = term_fixture(ends_on: ~D[2026-12-13])
    {:ok, view, _} = live(conn, ~p"/terms/#{term}/workload/new")
    render_hook(view, "selection_changed", %{"selected" => [ctx.cohort.id]})
    view |> form("#workload-form", workload: form_attrs(ctx, "45")) |> render_change()
    view |> form("#workload-form", workload: %{duration_slots: "2"}) |> render_change()
    assert has_element?(view, "#workload-preview-total", "12 sessions, 48 academic hours")
    render_hook(view, "week_mask_changed", %{"preset" => "odd"})
    assert has_element?(view, "#workload_contact_hours[value='45']")
    assert has_element?(view, "#workload_duration_slots option[value='2'][selected]")
    assert has_element?(view, "#workload-preview-pattern", "Odd weeks: 1 session")
    view |> form("#workload-form", workload: %{contact_hours: ""}) |> render_change()
    refute has_element?(view, "#workload-preview")
  end

  test "the 45-hour scenario is translated for Russian administrators", %{conn: conn} = ctx do
    term = term_fixture(ends_on: ~D[2026-12-13])
    conn = Plug.Test.init_test_session(conn, %{"locale" => "ru"})
    {:ok, view, _} = live(conn, ~p"/terms/#{term}/workload/new")
    render_hook(view, "selection_changed", %{"selected" => [ctx.cohort.id]})
    view |> form("#workload-form", workload: form_attrs(ctx, "45")) |> render_change()

    assert has_element?(view, "#workload_duration_slots option[value='1']", "90 мин, 2 акад. ч")
    assert has_element?(view, "#workload-preview-total", "23 занятия, 46 акад. ч")
    assert has_element?(view, "#workload-hours-difference", "Требуемые часы сохранятся: 45")
    assert has_element?(view, "#workload-preview-pattern", "Каждая неделя: 1 занятие")
    view |> form("#workload-form") |> render_submit()
    assert_patch(view, ~p"/terms/#{term}/workload")
  end

  test "required hours and small differences keep their entered precision", %{conn: conn} = ctx do
    term = term_fixture(ends_on: ~D[2026-12-13])
    {:ok, view, _} = live(conn, ~p"/terms/#{term}/workload/new")
    render_hook(view, "selection_changed", %{"selected" => [ctx.cohort.id]})
    view |> form("#workload-form", workload: form_attrs(ctx, "45.999")) |> render_change()

    assert has_element?(view, "#workload-preview-total", "23 sessions, 46 academic hours")
    assert has_element?(view, "#workload-hours-difference", "Required hours stay at 45.999")
    assert has_element?(view, "#workload-hours-difference", "Hours above the requirement: 0.001.")
    view |> form("#workload-form") |> render_submit()
    assert [row] = Catalog.list_workload(term.id)
    assert has_element?(view, "#workload-#{row.id}", "45.999")
    assert has_element?(view, "#workload-#{row.id}", "+0.001")

    view |> element("#workload-#{row.id} a", "Edit") |> render_click()
    view |> form("#workload-form", workload: %{contact_hours: "46.001"}) |> render_change()
    view |> form("#workload-form", workload: %{rounding_mode: "down"}) |> render_change()
    assert has_element?(view, "#workload-hours-difference", "Hours below the requirement: 0.001.")
    view |> form("#workload-form") |> render_submit()
    assert has_element?(view, "#workload-#{row.id}", "46.001")
    assert has_element?(view, "#workload-#{row.id}", "-0.001")
  end

  for {locale, totals, capacity_error, weeks} <- [
        {"ru",
         [
           "1 занятие, 2 акад. ч",
           "2 занятия, 4 акад. ч",
           "5 занятий, 10 акад. ч",
           "21 занятие, 42 акад. ч"
         ], "Нагрузка превышает доступное учебное время.", "Недели 2, 5, 8, 11, 14"},
        {"de",
         [
           "1 Termin, 2 Unterrichtsstunden",
           "2 Termine, 4 Unterrichtsstunden",
           "5 Termine, 10 Unterrichtsstunden",
           "21 Termine, 42 Unterrichtsstunden"
         ], "Der Lehrumfang überschreitet die verfügbare Unterrichtszeit.",
         "Wochen 2, 5, 8, 11, 14"}
      ] do
    test "#{locale} localizes workload plural forms, explicit weeks and capacity alternatives",
         %{conn: conn} = ctx do
      term = term_fixture(ends_on: ~D[2026-12-13])
      conn = Plug.Test.init_test_session(conn, %{"locale" => unquote(locale)})
      {:ok, view, _} = live(conn, ~p"/terms/#{term}/workload/new")
      render_hook(view, "selection_changed", %{"selected" => [ctx.cohort.id]})

      for {hours, total} <- Enum.zip(["2", "4", "10", "42"], unquote(totals)) do
        view |> form("#workload-form", workload: form_attrs(ctx, hours)) |> render_change()
        assert has_element?(view, "#workload-preview-total", total)

        if hours == "10",
          do: assert(has_element?(view, "#workload-preview-pattern", unquote(weeks)))
      end

      small =
        term_fixture(
          ends_on: ~D[2026-09-06],
          grid: %{
            days: ["Mon"],
            slots: [%{start: "08:00", end: "09:30"}, %{start: "09:50", end: "11:20"}]
          }
        )

      {:ok, view, _} = live(conn, ~p"/terms/#{small}/workload/new")
      render_hook(view, "selection_changed", %{"selected" => [ctx.cohort.id]})
      view |> form("#workload-form", workload: form_attrs(ctx, "5")) |> render_change()
      assert has_element?(view, "#workload-capacity-error", unquote(capacity_error))

      assert has_element?(
               view,
               "#workload_rounding_mode option[value='down']",
               Enum.at(unquote(totals), 1)
             )

      refute has_element?(view, "#workload-capacity-error", "Teaching load exceeds")

      view |> form("#workload-form", workload: %{rounding_mode: "down"}) |> render_change()
      refute has_element?(view, "#workload-capacity-error")
      view |> form("#workload-form") |> render_submit()
      assert_patch(view, ~p"/terms/#{small}/workload")
      [saved] = Workloads.list(small.id)
      assert Decimal.equal?(saved.requirement.contact_hours, 5)
      assert Decimal.equal?(Workloads.planned_hours(saved, small), 4)
    end
  end

  test "irregular distributions show their actual weeks before and after saving",
       %{conn: conn} = ctx do
    term = term_fixture(ends_on: ~D[2026-12-13])
    {:ok, view, _} = live(conn, ~p"/terms/#{term}/workload/new")
    render_hook(view, "selection_changed", %{"selected" => [ctx.cohort.id]})
    view |> form("#workload-form", workload: form_attrs(ctx, "10")) |> render_change()

    assert has_element?(view, "#workload-preview-pattern", "Weeks 2, 5, 8, 11, 14: 1 session")
    view |> form("#workload-form") |> render_submit()
    assert [row] = Catalog.list_workload(term.id)
    assert has_element?(view, "#workload-#{row.id}", "Weeks 2, 5, 8, 11, 14: 1 session")
  end

  test "an over-capacity rounded choice can be changed to the fitting lower choice",
       %{conn: conn} = ctx do
    term =
      term_fixture(
        ends_on: ~D[2026-09-06],
        grid: %{
          days: ["Mon"],
          slots: [%{start: "08:00", end: "09:30"}, %{start: "09:50", end: "11:20"}]
        }
      )

    {:ok, view, _} = live(conn, ~p"/terms/#{term}/workload/new")
    render_hook(view, "selection_changed", %{"selected" => [ctx.cohort.id]})
    view |> form("#workload-form", workload: form_attrs(ctx, "5")) |> render_change()

    assert has_element?(
             view,
             "#workload_rounding_mode option[value='down']",
             "2 sessions, 4 academic hours"
           )

    assert has_element?(
             view,
             "#workload-capacity-error",
             "Teaching load exceeds the available time."
           )

    refute has_element?(view, "#workload-preview-pattern")
    view |> form("#workload-form") |> render_submit()
    assert Workloads.list(term.id) == []
    assert has_element?(view, "select#workload_rounding_mode")

    view |> form("#workload-form", workload: %{rounding_mode: "down"}) |> render_change()
    refute has_element?(view, "#workload-capacity-error")
    assert has_element?(view, "#workload-preview-pattern", "Every week: 2 sessions")
    view |> form("#workload-form") |> render_submit()
    assert_patch(view, ~p"/terms/#{term}/workload")
    assert [row] = Workloads.list(term.id)
    assert Decimal.equal?(row.requirement.contact_hours, 5)
    assert Decimal.equal?(Workloads.planned_hours(row, term), 4)
  end

  test "preview and saved sessions use the semester's 30-minute hour unit", %{conn: conn} = ctx do
    term = term_fixture(academic_hour_minutes: 30)
    {:ok, view, _} = live(conn, ~p"/terms/#{term}/workload/new")
    render_hook(view, "selection_changed", %{"selected" => [ctx.cohort.id]})
    view |> form("#workload-form", workload: form_attrs(ctx, "7")) |> render_change()

    assert has_element?(
             view,
             "#workload_duration_slots option[value='1']",
             "90 min, 3 academic hours"
           )

    assert has_element?(view, "#workload-preview-total", "3 sessions, 9 academic hours")
    view |> form("#workload-form", workload: %{rounding_mode: "down"}) |> render_change()
    assert has_element?(view, "#workload-preview-total", "2 sessions, 6 academic hours")
    view |> form("#workload-form") |> render_submit()
    assert [row] = Workloads.list(term.id)
    assert Decimal.equal?(row.requirement.contact_hours, 7)
    assert Decimal.equal?(Workloads.planned_hours(row, term), 6)
    view |> element("#workload-#{row.id} a", "Edit") |> render_click()
    assert has_element?(view, "#workload-preview-total", "2 sessions, 6 academic hours")
  end

  test "editing previews the protected remainder that saving retains", %{conn: conn} = ctx do
    term = term_fixture(ends_on: ~D[2026-12-13])
    attrs = Map.merge(ctx.attrs, %{contact_hours: "45", week_mask: Enum.to_list(1..15)})
    assert {:ok, :saved} = Workloads.save(term.id, nil, attrs)
    [row] = Workloads.list(term.id)
    original_remainder = Enum.find(row.sessions, &(length(&1.week_mask) == 8))

    assert {:ok, _} =
             Sessions.update_generated_session(original_remainder, %{
               week_mask: [1, 2, 4, 6, 8, 10, 12, 14]
             })

    assert {:ok, _} =
             Sessions.create_generated_session(
               row.id,
               Map.merge(attrs, %{
                 term_id: term.id,
                 automatic_weeks: false,
                 week_mask: [2, 4, 6, 8, 10, 12, 14, 15]
               })
             )

    row.requirement |> Ecto.Changeset.change(contact_hours: Decimal.new(62)) |> Repo.update!()
    [row] = Workloads.list(term.id)
    remainders = Enum.filter(row.sessions, &(length(&1.week_mask) == 8))
    protected = Enum.max_by(remainders, & &1.id)
    unprotected = Enum.min_by(remainders, & &1.id)
    plan = plan_fixture(term: term)

    placement_fixture(
      plan_id: plan.id,
      session_id: protected.id,
      room_id: hd(ctx.component.allowed_rooms).id,
      day: 1,
      slot: 1,
      week_mask: protected.week_mask
    )

    {:ok, view, _} = live(conn, ~p"/terms/#{term}/workload/#{row.id}/edit")
    view |> form("#workload-form", workload: %{contact_hours: "45"}) |> render_change()

    pattern =
      if hd(protected.week_mask) == 1,
        do: "Weeks 1-2, 4, 6, 8, 10, 12, 14: 1 session",
        else: "Weeks 2, 4, 6, 8, 10, 12, 14-15: 1 session"

    assert has_element?(view, "#workload-preview-pattern", pattern)
    view |> form("#workload-form") |> render_submit()
    assert_patch(view, ~p"/terms/#{term}/workload")
    assert [saved] = Workloads.list(term.id)
    assert Enum.any?(saved.sessions, &(&1.id == protected.id))
    refute Enum.any?(saved.sessions, &(&1.id == unprotected.id))
    assert has_element?(view, "#workload-#{row.id}", pattern)
  end

  defp form_attrs(ctx, hours) do
    %{
      course_component_id: ctx.component.id,
      teacher_id: ctx.teacher.id,
      contact_hours: hours,
      duration_slots: "1",
      slot_profile_id: ""
    }
  end
end
