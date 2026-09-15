defmodule NeuZeitWeb.ExceptionLiveTest do
  use NeuZeitWeb.ConnCase, async: true

  alias NeuZeit.{Catalog, Planning}

  setup do
    {:ok, term} =
      Catalog.create_term(%{
        "name" => "Wintersemester 2026/27",
        "starts_on" => "2026-09-07",
        "ends_on" => "2026-12-20",
        "excluded_dates" => [~D[2026-09-21]]
      })

    {:ok, building} = Catalog.create_building(%{"name" => "Hauptgebäude"})
    {:ok, room} = Catalog.create_room(%{"building_id" => building.id, "name" => "101"})
    {:ok, other_room} = Catalog.create_room(%{"building_id" => building.id, "name" => "102"})
    {:ok, plan} = Planning.create_plan(%{"term_id" => term.id, "name" => "Entwurf 1"})
    {:ok, cohort} = Catalog.create_cohort(%{"name" => "WI-1"})
    {:ok, teacher} = Catalog.create_teacher(%{"name" => "Anna Weber"})
    {:ok, course} = Catalog.create_course(%{"code" => "INF110", "title" => "Programming"})

    {:ok, component} =
      Catalog.create_course_component(%{
        "course_id" => course.id,
        "kind" => "lecture",
        "allowed_room_ids" => [room.id, other_room.id]
      })

    {:ok, session} =
      NeuZeit.Fixtures.create_session(%{
        "term_id" => term.id,
        "course_component_id" => component.id,
        "teacher_id" => teacher.id,
        "week_mask" => [1, 2, 3, 4],
        "duration_slots" => 1,
        "cohort_ids" => [cohort.id]
      })

    {:ok, _placement} =
      Planning.create_placement(%{
        "plan_id" => plan.id,
        "session_id" => session.id,
        "room_id" => room.id,
        "day" => 1,
        "slot" => 1
      })

    {:ok, plan} = Planning.publish_plan(plan.id)

    %{term: term, plan: plan, session: session, room: room, other_room: other_room}
  end

  defp fill(live, attrs) do
    live |> form("#exception-form", schedule_exception: attrs) |> render_submit()
  end

  # The new-date, slot and room fields only appear once the kind calls for them:
  # a cancellation must not carry them, and the domain rejects it if it does.
  defp choose_kind(live, kind) do
    live
    |> form("#exception-form", schedule_exception: %{kind: kind})
    |> render_change()

    live
  end

  test "an empty term says so", %{conn: conn, term: term} do
    {:ok, live, _html} = live(conn, ~p"/terms/#{term}/exceptions")
    assert has_element?(live, "h1", "One-off changes")
    assert render(live) =~ "No one-off changes"
  end

  @tag locale: "ru"
  test "the replacement form uses the Russian scheduling terms", ctx do
    {:ok, view, _} =
      live(
        ctx.conn,
        ~p"/terms/#{ctx.term}/exceptions/new?kind=substitute&session_id=#{ctx.session.id}&date=2026-09-14"
      )

    assert has_element?(view, "#exception-form", "Заменяющий преподаватель")
    assert has_element?(view, "#exception-form button", "Заменить преподавателя")
    refute render(view) =~ "Rename teacher"
  end

  test "records a substitute from the calendar and shows its teacher on just that date", ctx do
    teacher = NeuZeit.Fixtures.teacher_fixture(name: "Substitute teacher name")
    {:ok, calendar, _} = live(ctx.conn, ~p"/terms/#{ctx.term}/calendar?week=2")
    calendar |> element("#calendar-day-2026-09-14 a", "Replace teacher") |> render_click()
    {path, _} = assert_redirect(calendar)
    {:ok, view, _} = live(ctx.conn, path)
    refute has_element?(view, "select[name='schedule_exception[new_room_id]']")
    refute has_element?(view, "input[name='schedule_exception[new_date]']")
    fill(view, %{new_teacher_id: teacher.id, reason: "Teacher absent", created_by: "Admin"})
    [exception] = Planning.list_schedule_exceptions(ctx.term.id)
    assert exception.kind == "substitute"
    assert exception.new_teacher_id == teacher.id
    assert {exception.new_date, exception.new_slot, exception.new_room_id} == {nil, nil, nil}
    {return_path, _} = assert_redirect(view)
    {:ok, calendar, _} = live(ctx.conn, return_path)
    assert has_element?(calendar, "#calendar-day-2026-09-14", teacher.name)
    assert has_element?(calendar, "#calendar-day-2026-09-14", "Teacher replaced")
    refute has_element?(calendar, "#calendar-day-2026-09-14", "Anna Weber")

    calendar
    |> element("form[phx-change='select_scope']")
    |> render_change(%{"scope" => ctx.session.teacher_id})

    refute has_element?(calendar, "#calendar-day-2026-09-14", "Programming")

    calendar
    |> element("form[phx-change='select_scope']")
    |> render_change(%{"scope" => teacher.id})

    assert has_element?(calendar, "#calendar-day-2026-09-14", "Programming")
  end

  test "dragging a substituted class preserves the replacement and prefills its new position",
       ctx do
    teacher = NeuZeit.Fixtures.teacher_fixture()

    {:ok, exception} =
      Planning.create_schedule_exception(%{
        session_id: ctx.session.id,
        kind: "substitute",
        occurrence_date: ~D[2026-09-14],
        new_teacher_id: teacher.id,
        reason: "Cover",
        created_by: "Admin"
      })

    {:ok, calendar, _} = live(ctx.conn, ~p"/terms/#{ctx.term}/calendar?week=2")

    render_hook(calendar, "move_occurrence", %{
      "session-id" => ctx.session.id,
      "exception-id" => exception.id,
      "from" => "2026-09-14",
      "to" => "2026-09-15"
    })

    {path, _} = assert_redirect(calendar)
    {:ok, view, _} = live(ctx.conn, path)

    assert has_element?(
             view,
             "select[name='schedule_exception[new_teacher_id]'] option[selected][value='#{teacher.id}']"
           )

    fill(view, %{reason: "Cover moved to Tuesday", created_by: "Admin"})
    updated = Planning.get_schedule_exception!(exception.id)
    assert updated.kind == "move"
    assert updated.new_date == ~D[2026-09-15]
    assert updated.new_slot == 1
    assert updated.new_room_id == ctx.room.id
    assert updated.new_teacher_id == teacher.id
  end

  test "changing a substitution to a cancellation clears the replacement", ctx do
    teacher = NeuZeit.Fixtures.teacher_fixture()

    {:ok, exception} =
      Planning.create_schedule_exception(%{
        session_id: ctx.session.id,
        kind: "substitute",
        occurrence_date: ~D[2026-09-14],
        new_teacher_id: teacher.id,
        reason: "Cover",
        created_by: "Admin"
      })

    {:ok, view, _} = live(ctx.conn, ~p"/terms/#{ctx.term}/exceptions/#{exception.id}/edit")
    choose_kind(view, "cancel")
    refute has_element?(view, "select[name='schedule_exception[new_teacher_id]']")
    fill(view, %{reason: "Class cancelled", created_by: "Admin"})
    updated = Planning.get_schedule_exception!(exception.id)
    assert updated.kind == "cancel"
    assert updated.new_teacher_id == nil
  end

  test "records a cancellation with its reason and author", %{conn: conn} = ctx do
    {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/exceptions/new")

    fill(live, %{
      session_id: ctx.session.id,
      kind: "cancel",
      occurrence_date: "2026-09-14",
      reason: "Teacher at a conference",
      created_by: "admin"
    })

    assert [exception] = Planning.list_schedule_exceptions(ctx.term.id)
    assert exception.kind == "cancel"
    assert exception.reason == "Teacher at a conference"
    assert has_element?(live, "#exceptions", "Teacher at a conference")
  end

  test "automatic session choices show published weeks instead of eligible weeks", ctx do
    {:ok, session} =
      NeuZeit.Fixtures.create_session(%{
        term_id: ctx.term.id,
        course_component_id: ctx.session.course_component_id,
        teacher_id: ctx.session.teacher_id,
        cohort_ids: Enum.map(Catalog.get_session!(ctx.session.id).cohorts, & &1.id),
        week_mask: Enum.to_list(1..ctx.term.weeks_count),
        automatic_weeks: true,
        duration_slots: 1
      })

    {:ok, draft} = Planning.clone_plan(ctx.plan.id)

    {:ok, _} =
      Planning.create_placement(%{
        plan_id: draft.id,
        session_id: session.id,
        room_id: ctx.room.id,
        week_mask: [2],
        day: 2,
        slot: 1
      })

    {:ok, _} = Planning.publish_plan(draft.id)
    {:ok, view, _} = live(ctx.conn, ~p"/terms/#{ctx.term}/exceptions/new")
    option = ~s{select[name="schedule_exception[session_id]"] option[value="#{session.id}"]}

    assert has_element?(view, option, "Weeks 2")
    refute has_element?(view, option, "Every week")
  end

  test "records a move with its new date, slot and room", %{conn: conn} = ctx do
    {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/exceptions/new")

    live
    |> choose_kind("move")
    |> fill(%{
      session_id: ctx.session.id,
      kind: "move",
      occurrence_date: "2026-09-14",
      new_date: "2026-09-15",
      new_slot: 2,
      new_room_id: ctx.other_room.id,
      reason: "Room flooded",
      created_by: "admin"
    })

    assert [exception] = Planning.list_schedule_exceptions(ctx.term.id)
    assert exception.new_date == ~D[2026-09-15]
    assert exception.new_room_id == ctx.other_room.id
  end

  test "refuses a move onto a non-teaching day and says why", %{conn: conn} = ctx do
    {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/exceptions/new")

    html =
      live
      |> choose_kind("move")
      |> fill(%{
        session_id: ctx.session.id,
        kind: "move",
        occurrence_date: "2026-09-14",
        # 2026-09-21 is excluded: officially non-teaching.
        new_date: "2026-09-21",
        new_slot: 2,
        new_room_id: ctx.other_room.id,
        reason: "Trying the impossible",
        created_by: "admin"
      })

    assert Planning.list_schedule_exceptions(ctx.term.id) == []
    assert html =~ "excluded" or html =~ "non-teaching" or html =~ "teaching"
  end

  test "a reason is required", %{conn: conn} = ctx do
    {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/exceptions/new")

    fill(live, %{
      session_id: ctx.session.id,
      kind: "cancel",
      occurrence_date: "2026-09-14",
      reason: "",
      created_by: "admin"
    })

    assert Planning.list_schedule_exceptions(ctx.term.id) == []
  end

  test "editing a legacy addition uses one effective date and keeps the same record",
       %{conn: conn} = ctx do
    {:ok, added} =
      Planning.create_schedule_exception(%{
        session_id: ctx.session.id,
        occurrence_date: ~D[2026-09-08],
        new_date: ~D[2026-09-09],
        kind: "add",
        new_slot: 2,
        new_room_id: ctx.room.id,
        reason: "Extra class",
        created_by: "admin"
      })

    {:ok, view, _} = live(conn, ~p"/terms/#{ctx.term}/exceptions/#{added.id}/edit")

    assert has_element?(
             view,
             ~s{input[name="schedule_exception[occurrence_date]"][value="2026-09-09"]}
           )

    refute has_element?(view, ~s{input[name="schedule_exception[new_date]"]})

    fill(view, %{
      kind: "add",
      occurrence_date: "2026-09-10",
      new_slot: 2,
      new_room_id: ctx.room.id,
      reason: "Corrected extra class",
      created_by: "admin"
    })

    assert [corrected] = Planning.list_schedule_exceptions(ctx.term.id)
    assert corrected.id == added.id
    assert corrected.occurrence_date == ~D[2026-09-10]
    assert corrected.new_date == nil
  end

  test "reverting keeps the record", %{conn: conn} = ctx do
    {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/exceptions/new")

    fill(live, %{
      session_id: ctx.session.id,
      kind: "cancel",
      occurrence_date: "2026-09-14",
      reason: "Teacher ill",
      created_by: "admin"
    })

    [exception] = Planning.list_schedule_exceptions(ctx.term.id)

    live |> element(~s{button[phx-value-id="#{exception.id}"]}) |> render_click()
    assert has_element?(live, "#confirm-modal")
    live |> element("#confirm-modal button", "Revert change") |> render_click()

    # Reverting keeps the historical record.
    assert [reverted] = Planning.list_schedule_exceptions(ctx.term.id)
    assert reverted.status == "reverted"
    assert reverted.reason == "Teacher ill"
  end

  test "a cancellation removes the occurrence from the calendar", %{conn: conn} = ctx do
    {:ok, live, _html} = live(conn, ~p"/terms/#{ctx.term}/exceptions/new")

    fill(live, %{
      session_id: ctx.session.id,
      kind: "cancel",
      occurrence_date: "2026-09-14",
      reason: "Teacher ill",
      created_by: "admin"
    })

    {:ok, calendar, _html} = live(conn, ~p"/terms/#{ctx.term}/calendar")

    # Week 2's Monday is 2026-09-14, and it is the published plan, so the
    # exception applies there.
    calendar |> element(~s{button[aria-label="Next week"][phx-value-week="2"]}) |> render_click()

    assert has_element?(
             calendar,
             "#calendar-day-2026-09-14 [data-cancelled='true']",
             "Programming"
           )

    refute has_element?(
             calendar,
             "#calendar-day-2026-09-14 [data-cancelled='false']",
             "Programming"
           )

    calendar |> element(~s{button[phx-value-week="1"]}, "First") |> render_click()
    assert has_element?(calendar, "#calendar-day-2026-09-07", "Programming")
  end
end
