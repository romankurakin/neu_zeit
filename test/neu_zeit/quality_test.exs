defmodule NeuZeit.Planning.QualityTest do
  use NeuZeit.DataCase, async: true

  alias NeuZeit.{Catalog, Planning}
  alias NeuZeit.Planning.Quality

  setup do
    {:ok, term} =
      Catalog.create_term(%{
        "name" => "Wintersemester 2026/27",
        "starts_on" => "2026-09-07",
        "ends_on" => "2026-12-20"
      })

    {:ok, main} = Catalog.create_building(%{"name" => "Hauptgebäude"})
    {:ok, other} = Catalog.create_building(%{"name" => "Ingenieurgebäude"})
    {:ok, plan} = Planning.create_plan(%{"term_id" => term.id, "name" => "Entwurf 1"})
    {:ok, cohort} = Catalog.create_cohort(%{"name" => "WI-1"})

    %{term: term, main: main, other: other, plan: plan, cohort: cohort}
  end

  defp room(building, name) do
    {:ok, room} = Catalog.create_room(%{"building_id" => building.id, "name" => name})
    room
  end

  defp session(ctx, code, teacher_name, rooms, overrides \\ %{}) do
    {:ok, course} = Catalog.create_course(%{"code" => code, "title" => code})

    {:ok, component} =
      Catalog.create_course_component(%{
        "course_id" => course.id,
        "kind" => "lecture",
        "allowed_room_ids" => Enum.map(rooms, & &1.id)
      })

    {:ok, teacher} = Catalog.create_teacher(%{"name" => teacher_name})

    {:ok, session} =
      NeuZeit.Fixtures.create_session(
        Map.merge(
          %{
            "term_id" => ctx.term.id,
            "course_component_id" => component.id,
            "teacher_id" => teacher.id,
            "week_mask" => [1, 2],
            "duration_slots" => 1,
            "cohort_ids" => [ctx.cohort.id]
          },
          overrides
        )
      )

    session
  end

  defp place(ctx, session, room, day, slot) do
    {:ok, placement} =
      Planning.create_placement(%{
        "plan_id" => ctx.plan.id,
        "session_id" => session.id,
        "room_id" => room.id,
        "day" => day,
        "slot" => slot
      })

    placement
  end

  defp cohort_row(ctx), do: Quality.report(ctx.plan.id).cohorts |> hd()

  describe "gaps" do
    test "back-to-back classes leave none", ctx do
      first_room = room(ctx.main, "101")
      second_room = room(ctx.main, "102")

      place(ctx, session(ctx, "A", "Anna Weber", [first_room]), first_room, 1, 1)
      place(ctx, session(ctx, "B", "Erik Hoffmann", [second_room]), second_room, 1, 2)

      assert cohort_row(ctx).gaps == 0
    end

    test "an empty slot between two classes counts once per week", ctx do
      first_room = room(ctx.main, "101")
      second_room = room(ctx.main, "102")

      # Slots 1 and 3 on the same day: slot 2 is a gap, in each of two weeks.
      place(ctx, session(ctx, "A", "Anna Weber", [first_room]), first_room, 1, 1)
      place(ctx, session(ctx, "B", "Erik Hoffmann", [second_room]), second_room, 1, 3)

      assert cohort_row(ctx).gaps == 2
    end

    test "classes on different days never gap each other", ctx do
      first_room = room(ctx.main, "101")
      second_room = room(ctx.main, "102")

      place(ctx, session(ctx, "A", "Anna Weber", [first_room]), first_room, 1, 1)
      place(ctx, session(ctx, "B", "Erik Hoffmann", [second_room]), second_room, 2, 4)

      assert cohort_row(ctx).gaps == 0
    end
  end

  test "a day holding a single class is counted as isolated", ctx do
    first_room = room(ctx.main, "101")
    second_room = room(ctx.main, "102")

    place(ctx, session(ctx, "A", "Anna Weber", [first_room]), first_room, 1, 1)
    place(ctx, session(ctx, "B", "Erik Hoffmann", [second_room]), second_room, 1, 2)
    place(ctx, session(ctx, "C", "Jana Richter", [first_room]), first_room, 3, 1)

    row = cohort_row(ctx)

    # Across two weeks, day 1 has two sessions and day 3 has one.
    assert row.isolated_days == 2
    assert row.active_days == 2
  end

  test "counts a building change within a day", ctx do
    here = room(ctx.main, "101")
    across = room(ctx.other, "11")

    place(ctx, session(ctx, "A", "Anna Weber", [here]), here, 1, 1)
    place(ctx, session(ctx, "B", "Erik Hoffmann", [across]), across, 1, 2)

    # One move per week, in two weeks.
    assert cohort_row(ctx).building_transitions == 2
  end

  test "no building change when the day stays in one building", ctx do
    first_room = room(ctx.main, "101")
    second_room = room(ctx.main, "102")

    place(ctx, session(ctx, "A", "Anna Weber", [first_room]), first_room, 1, 1)
    place(ctx, session(ctx, "B", "Erik Hoffmann", [second_room]), second_room, 1, 2)

    assert cohort_row(ctx).building_transitions == 0
  end

  test "teachers are measured the same way as cohorts", ctx do
    here = room(ctx.main, "101")
    across = room(ctx.other, "11")

    {:ok, shared} = Catalog.create_teacher(%{"name" => "Anna Weber"})

    for {code, room, slot} <- [{"A", here, 1}, {"B", across, 2}] do
      {:ok, course} = Catalog.create_course(%{"code" => code, "title" => code})

      {:ok, component} =
        Catalog.create_course_component(%{
          "course_id" => course.id,
          "kind" => "lecture",
          "allowed_room_ids" => [room.id]
        })

      {:ok, created} =
        NeuZeit.Fixtures.create_session(%{
          "term_id" => ctx.term.id,
          "course_component_id" => component.id,
          "teacher_id" => shared.id,
          "week_mask" => [1],
          "duration_slots" => 1,
          "cohort_ids" => [ctx.cohort.id]
        })

      place(ctx, created, room, 1, slot)
    end

    # Measure building changes for teachers as well as groups.
    assert [teacher_row] = Quality.report(ctx.plan.id).teachers
    assert teacher_row.name == "Anna Weber"
    assert teacher_row.building_transitions == 1
  end

  describe "sequences" do
    test "adjacent blocks on one day are reported as side by side", ctx do
      first_room = room(ctx.main, "101")
      second_room = room(ctx.main, "102")

      a = session(ctx, "A", "Anna Weber", [first_room], %{"sequence_group" => "LAB"})
      b = session(ctx, "B", "Erik Hoffmann", [second_room], %{"sequence_group" => "LAB"})

      place(ctx, a, first_room, 1, 1)
      place(ctx, b, second_room, 1, 2)

      assert [%{group: "LAB", adjacent: true, placements: 2}] =
               Quality.report(ctx.plan.id).sequences
    end

    test "blocks on different days are reported as split", ctx do
      first_room = room(ctx.main, "101")
      second_room = room(ctx.main, "102")

      a = session(ctx, "A", "Anna Weber", [first_room], %{"sequence_group" => "LAB"})
      b = session(ctx, "B", "Erik Hoffmann", [second_room], %{"sequence_group" => "LAB"})

      place(ctx, a, first_room, 1, 1)
      place(ctx, b, second_room, 3, 1)

      assert [%{adjacent: false, days: [1, 3]}] = Quality.report(ctx.plan.id).sequences
    end

    test "a group with one member is not a sequence", ctx do
      only = room(ctx.main, "101")
      a = session(ctx, "A", "Anna Weber", [only], %{"sequence_group" => "LAB"})
      place(ctx, a, only, 1, 1)

      assert Quality.report(ctx.plan.id).sequences == []
    end
  end

  test "flags an unexplained hole in a teaching calendar", ctx do
    first_room = room(ctx.main, "101")
    second_room = room(ctx.main, "102")

    early = session(ctx, "A", "Anna Weber", [first_room], %{"week_mask" => [1, 2]})
    late = session(ctx, "B", "Erik Hoffmann", [second_room], %{"week_mask" => [12, 13]})

    place(ctx, early, first_room, 1, 1)
    place(ctx, late, second_room, 2, 1)

    row = cohort_row(ctx)

    # Weeks 3 through 11 form an internal break longer than four weeks.
    assert row.first_week == 1
    assert row.last_week == 13
    assert row.calendar_gap == 9
    assert Quality.verdicts(Quality.report(ctx.plan.id)).calendar_gaps > 0
  end

  test "reports room load, busiest first", ctx do
    busy = room(ctx.main, "101")
    quiet = room(ctx.main, "102")

    place(ctx, session(ctx, "A", "Anna Weber", [busy]), busy, 1, 1)
    place(ctx, session(ctx, "B", "Erik Hoffmann", [busy]), busy, 2, 1)
    place(ctx, session(ctx, "C", "Jana Richter", [quiet]), quiet, 3, 1)

    assert [first, second] = Quality.report(ctx.plan.id).rooms
    assert first.name == "101" and first.placements == 2
    assert second.name == "102" and second.placements == 1
  end

  test "an empty plan reports nothing rather than failing", ctx do
    report = Quality.report(ctx.plan.id)

    assert report.cohorts == []
    assert report.teachers == []
    assert Quality.verdicts(report).gaps == 0
  end
end
