defmodule NeuZeitWeb.AdminWorkflowsTest do
  use NeuZeitWeb.ConnCase, async: true
  import NeuZeit.Fixtures
  alias NeuZeit.{Catalog, Planning}

  setup do
    term = term_fixture()
    rooms = [room_fixture(), room_fixture()]
    component = component_fixture(rooms: rooms)
    session = session_fixture(term: term, component: component, week_mask: [1, 2])
    plan = plan_fixture(term: term)
    %{term: term, rooms: rooms, component: component, session: session, plan: plan}
  end

  test "unplaced selection, resource filters and rule return links preserve context", c do
    {:ok, view, _} =
      live(
        c.conn,
        ~p"/terms/#{c.term}/plans/#{c.plan}?session=#{c.session.id}&week=2&lens=room&resource=#{hd(c.rooms).id}"
      )

    assert has_element?(view, "#session-inspector", c.session.teacher.name)
    assert has_element?(view, "#selection-scope", "Weeks 1-2")
    view |> element("#board-cell-1-1 > button") |> render_click()
    assert has_element?(view, "#position-preview", hd(c.rooms).name)
    assert Planning.list_placements(c.plan.id) == []
    view |> element("#board-filters") |> render_change(%{"resource" => ""})
    assert has_element?(view, "#board-tray", c.session.course_component.course.code)
    html = render(view) |> LazyHTML.from_fragment()

    [link] =
      html
      |> LazyHTML.query("a[href*='/sessions/#{c.session.id}/edit']")
      |> LazyHTML.attribute("href")

    return_to = URI.decode_query(URI.parse(link).query)["return_to"]
    assert return_to =~ "session=#{c.session.id}"
    assert return_to =~ "week=2"
  end

  test "room changes and locks are undone in order", c do
    [a, b] = c.rooms

    placement_fixture(%{
      plan_id: c.plan.id,
      session_id: c.session.id,
      room_id: a.id,
      day: 1,
      slot: 1
    })

    {:ok, view, _} = live(c.conn, ~p"/terms/#{c.term}/plans/#{c.plan}?session=#{c.session.id}")
    view |> element("#placement-room") |> render_change(%{"room_id" => b.id})
    view |> element("button[phx-click='toggle_lock']") |> render_click()
    assert [%{locked: true, room_id: room_id}] = Planning.list_placements(c.plan.id)
    assert room_id == b.id
    view |> element("button[phx-click='undo']") |> render_click()
    assert [%{locked: false, room_id: ^room_id}] = Planning.list_placements(c.plan.id)
    view |> element("button[phx-click='undo']") |> render_click()
    assert [%{room_id: restored}] = Planning.list_placements(c.plan.id)
    assert restored == a.id
  end

  test "a failed undo keeps the entry available and a stale solver failure keeps manual history",
       c do
    room = hd(c.rooms)

    placement_fixture(%{
      plan_id: c.plan.id,
      session_id: c.session.id,
      room_id: room.id,
      day: 1,
      slot: 1
    })

    other = session_fixture(term: c.term, component: c.component)
    {:ok, view, _} = live(c.conn, ~p"/terms/#{c.term}/plans/#{c.plan}?session=#{c.session.id}")
    view |> element("button[phx-click='unplace_selected']") |> render_click()

    conflict =
      placement_fixture(%{
        plan_id: c.plan.id,
        session_id: other.id,
        room_id: room.id,
        day: 1,
        slot: 1
      })

    view |> element("button[phx-click='undo']") |> render_click()
    refute has_element?(view, "button[phx-click='undo'][disabled]")
    {:ok, _} = Planning.delete_placement(conflict)
    send(view.pid, {:solve_finished, c.plan.id, {:error, {:conflict, "stale"}}})
    view |> element("button[phx-click='undo']") |> render_click()
    assert [%{session_id: restored}] = Planning.list_placements(c.plan.id)
    assert restored == c.session.id
  end

  test "nested records cannot be opened under a different term", c do
    other = term_fixture()
    profile = slot_profile_fixture(term: c.term)

    for path <- [
          ~p"/terms/#{other}/plans/#{c.plan}",
          ~p"/terms/#{other}/sessions/#{c.session}/edit",
          ~p"/terms/#{other}/slot-profiles/#{profile}/edit",
          ~p"/terms/#{other}/plans/#{c.plan}/rename"
        ] do
      assert_raise Ecto.NoResultsError, fn -> live(c.conn, path) end
    end
  end

  test "session filters combine course, cohort and unplaced status and persist in the URL", c do
    extra = session_fixture(term: c.term, component: c.component, cohorts: c.session.cohorts)

    placement_fixture(%{
      plan_id: c.plan.id,
      session_id: c.session.id,
      room_id: hd(c.rooms).id,
      day: 1,
      slot: 1
    })

    filters = %{
      course_id: c.component.course_id,
      cohort_id: hd(c.session.cohorts).id,
      unplaced_in_plan: c.plan.id
    }

    assert [found] = Catalog.list_sessions(c.term.id, filters, page: 1, per_page: 1)
    assert found.id == extra.id
    assert Catalog.count_sessions(c.term.id, filters) == 1
    {:ok, view, _} = live(c.conn, ~p"/terms/#{c.term}/sessions?#{filters}")
    assert has_element?(view, "#sessions-#{extra.id}")
    refute has_element?(view, "#sessions-#{c.session.id}")
  end

  test "an already moved sitting opens the same exception for correction", c do
    room = hd(c.rooms)

    placement_fixture(%{
      plan_id: c.plan.id,
      session_id: c.session.id,
      room_id: room.id,
      day: 1,
      slot: 1
    })

    {:ok, _} = Planning.publish_plan(c.plan.id)

    {:ok, move} =
      Planning.create_schedule_exception(%{
        session_id: c.session.id,
        kind: "move",
        occurrence_date: ~D[2026-08-31],
        new_date: ~D[2026-09-01],
        new_slot: 2,
        new_room_id: room.id,
        reason: "Teacher request",
        created_by: "Admin"
      })

    {:ok, view, _} = live(c.conn, ~p"/terms/#{c.term}/calendar")

    render_hook(view, "move_occurrence", %{
      "session-id" => c.session.id,
      "exception-id" => move.id,
      "from" => "2026-09-01",
      "to" => "2026-09-02"
    })

    {path, _} = assert_redirect(view)
    assert URI.parse(path).path == "/terms/#{c.term.id}/exceptions/#{move.id}/edit"
    {:ok, editor, _} = live(c.conn, path)

    assert has_element?(
             editor,
             "input[name='schedule_exception[occurrence_date]'][value='2026-08-31']"
           )

    assert has_element?(editor, "input[name='schedule_exception[new_date]'][value='2026-09-02']")

    editor
    |> form("#exception-form",
      schedule_exception: %{reason: "Corrected date", created_by: "Admin"}
    )
    |> render_submit()

    assert Planning.get_schedule_exception!(move.id).new_date == ~D[2026-09-02]
    assert length(Planning.list_schedule_exceptions(c.term.id)) == 1
  end

  test "extra unplaced sessions appear in the calendar and room filter", c do
    room = hd(c.rooms)

    placement_fixture(%{
      plan_id: c.plan.id,
      session_id: c.session.id,
      room_id: room.id,
      day: 1,
      slot: 1
    })

    {:ok, _} = Planning.publish_plan(c.plan.id)
    extra = session_fixture(term: c.term, component: c.component)

    {:ok, _} =
      Planning.create_schedule_exception(%{
        session_id: extra.id,
        kind: "add",
        occurrence_date: ~D[2026-09-02],
        new_slot: 3,
        new_room_id: room.id,
        reason: "Extra class",
        created_by: "Admin"
      })

    {:ok, view, _} = live(c.conn, ~p"/terms/#{c.term}/calendar?scope=#{room.id}")
    assert has_element?(view, "#calendar-day-2026-09-02 [data-session-id='#{extra.id}']", "Added")
  end

  test "plan coverage API preserves planned versus calendar semantics and legacy metadata", c do
    response = get(c.conn, "/api/plans/#{c.plan.id}/coverage") |> json_response(200)

    assert %{"meta" => %{"basis" => "planned_and_calendar", "plan_id" => id}, "data" => [row]} =
             response

    assert id == c.plan.id
    assert row["planned_hours"] == 3.0
    assert row["calendar_hours"] == 0.0
    assert row["cohort_id"] == hd(c.session.cohorts).id
    legacy = get(c.conn, "/api/terms/#{c.term.id}/coverage") |> json_response(200)
    assert legacy["meta"]["basis"] == "session_definitions"
    assert hd(legacy["data"])["scheduled_hours"] == 3.0
  end
end
