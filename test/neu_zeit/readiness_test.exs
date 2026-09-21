defmodule NeuZeit.Planning.ReadinessTest do
  use NeuZeit.DataCase, async: true

  alias NeuZeit.Catalog
  alias NeuZeit.Planning
  alias NeuZeit.Planning.Readiness

  setup do
    {:ok, term} =
      Catalog.create_term(%{
        "name" => "Wintersemester 2026/27",
        "starts_on" => "2026-09-07",
        "ends_on" => "2026-12-20"
      })

    {:ok, building} = Catalog.create_building(%{"name" => "Hauptgebäude"})
    {:ok, cohort} = Catalog.create_cohort(%{"name" => "WI-1"})
    %{term: term, building: building, cohort: cohort}
  end

  defp room(ctx, name) do
    {:ok, room} = Catalog.create_room(%{"building_id" => ctx.building.id, "name" => name})
    room
  end

  defp component(_ctx, code, rooms) do
    {:ok, course} = Catalog.create_course(%{"code" => code, "title" => code})

    {:ok, component} =
      Catalog.create_course_component(%{
        "course_id" => course.id,
        "kind" => "lecture",
        "allowed_room_ids" => Enum.map(rooms, & &1.id)
      })

    component
  end

  defp session(ctx, component, teacher, overrides \\ %{}) do
    {:ok, session} =
      NeuZeit.Fixtures.create_session(
        Map.merge(
          %{
            "term_id" => ctx.term.id,
            "course_component_id" => component.id,
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

  defp teacher(name) do
    {:ok, teacher} = Catalog.create_teacher(%{"name" => name})
    teacher
  end

  defp row(report, key), do: Enum.find(report, &(&1.key == key))

  test "a term with nothing in it blocks only on unplaced sessions", %{term: term} do
    report = Readiness.report(term.id)

    assert row(report, :placeholder_teachers).status == :ok
    assert row(report, :room_pools).status == :ok
    # With no plan, the plan-specific rows cannot be judged.
    assert row(report, :unplaced).status == :unknown
    assert row(report, :hard_checks).status == :unknown
  end

  test "flags an abbreviation standing in for a teacher", ctx do
    component = component(ctx, "INF110", [room(ctx, "101"), room(ctx, "102")])
    session(ctx, component, teacher("Lch"))

    found = row(Readiness.report(ctx.term.id), :placeholder_teachers)

    assert found.status == :warning
    assert found.count == 1
    assert [%{name: "Lch"}] = found.detail.teachers
  end

  describe "room pools" do
    test "blocks an in-person component when the institution has no rooms", ctx do
      component = component(ctx, "X0", [])
      session(ctx, component, teacher("Anna Weber"))

      found = row(Readiness.report(ctx.term.id), :room_pools)

      assert found.status == :blocked
      assert found.count == 1
      assert [%{course_code: "X0", rooms: 0}] = found.detail.missing
    end

    test "does not require a physical room for online teaching", ctx do
      component = component(ctx, "WEB0", [])
      session(ctx, component, teacher("Anna Weber"), %{"delivery_mode" => :online})

      found = row(Readiness.report(ctx.term.id), :room_pools)

      assert found.status == :ok
      assert found.count == 0
      assert found.detail.missing == []
    end

    test "an empty room selection means every institution room", ctx do
      rooms = for n <- 1..3, do: room(ctx, "10#{n}")
      component = component(ctx, "X1", [hd(rooms)])
      session(ctx, component, teacher("Anna Weber"))

      assert {:ok, _component} =
               Catalog.update_course_component(component, %{"allowed_room_ids" => []})

      assert Catalog.get_course_component!(component.id).allowed_rooms == []

      found = row(Readiness.report(ctx.term.id), :room_pools)
      assert found.status == :ok
      assert found.count == 0
    end

    test "warns on a pool of one and on a pool of more than five", ctx do
      rooms = for n <- 1..6, do: room(ctx, "10#{n}")

      narrow = component(ctx, "NARROW", Enum.take(rooms, 1))
      broad = component(ctx, "BROAD", rooms)
      fine = component(ctx, "FINE", Enum.take(rooms, 3))

      session(ctx, narrow, teacher("Anna Weber"))
      session(ctx, broad, teacher("Erik Hoffmann"))
      session(ctx, fine, teacher("Jana Richter"))

      found = row(Readiness.report(ctx.term.id), :room_pools)

      assert found.status == :warning
      assert [%{course_code: "NARROW"}] = found.detail.narrow
      assert [%{course_code: "BROAD"}] = found.detail.broad
    end
  end

  test "offers a duplicated shared lecture for merging", ctx do
    component = component(ctx, "MAT101", [room(ctx, "101"), room(ctx, "102")])
    lecturer = teacher("Christoph Lehmann")
    {:ok, other} = Catalog.create_cohort(%{"name" => "WI-2"})

    session(ctx, component, lecturer)
    session(ctx, component, lecturer, %{"cohort_ids" => [other.id]})

    found = row(Readiness.report(ctx.term.id), :merge_candidates)

    assert found.status == :warning
    assert found.count == 1
    assert [%{course_code: "MAT101", cohorts: ["WI-1", "WI-2"]}] = found.detail.groups
  end

  test "does not confuse two genuinely different sessions", ctx do
    component = component(ctx, "MAT101", [room(ctx, "101"), room(ctx, "102")])

    # Different teachers exclude these sessions from duplicate candidates.
    session(ctx, component, teacher("Anna Weber"))
    session(ctx, component, teacher("Erik Hoffmann"))

    assert row(Readiness.report(ctx.term.id), :merge_candidates).status == :ok
  end

  test "flags a cohort name that looks aggregated", ctx do
    component = component(ctx, "SPO100", [room(ctx, "Sporthalle")])
    {:ok, aggregate} = Catalog.create_cohort(%{"name" => "ФК(д)"})
    session(ctx, component, teacher("Anna Weber"), %{"cohort_ids" => [aggregate.id]})

    found = row(Readiness.report(ctx.term.id), :aggregate_cohorts)
    assert found.status == :warning
    assert [%{name: "ФК(д)"}] = found.detail.cohorts
  end

  test "unrestricted availability asks for confirmation rather than failing", ctx do
    component = component(ctx, "INF110", [room(ctx, "101"), room(ctx, "102")])
    restricted = teacher("Marat Zhaksylykov")
    session(ctx, component, restricted)

    found = row(Readiness.report(ctx.term.id), :teacher_availability)
    assert found.status == :unknown
    assert found.count == 1

    {:ok, _} =
      Catalog.replace_teacher_availability(ctx.term.id, restricted.id, [
        %{"day" => 6, "slot" => 1}
      ])

    assert row(Readiness.report(ctx.term.id), :teacher_availability).status == :ok
  end

  describe "against a plan" do
    setup ctx do
      {:ok, plan} = Planning.create_plan(%{"term_id" => ctx.term.id, "name" => "Entwurf 1"})
      Map.put(ctx, :plan, plan)
    end

    test "unplaced sessions warn without blocking a solve", ctx do
      component = component(ctx, "INF110", [room(ctx, "101"), room(ctx, "102")])
      session(ctx, component, teacher("Anna Weber"))

      report = Readiness.report(ctx.term.id, ctx.plan.id)

      assert row(report, :unplaced).status == :warning
      assert row(report, :unplaced).count == 1
      assert Readiness.solvable?(report)
    end

    test "an empty term with an empty plan is solvable", ctx do
      report = Readiness.report(ctx.term.id, ctx.plan.id)

      assert row(report, :unplaced).status == :ok
      assert row(report, :hard_checks).status == :ok
      assert Readiness.solvable?(report)
    end

    test "counts locked placements", ctx do
      first = room(ctx, "101")
      component = component(ctx, "INF110", [first, room(ctx, "102")])
      created = session(ctx, component, teacher("Anna Weber"))

      {:ok, _placement} =
        Planning.create_placement(%{
          "plan_id" => ctx.plan.id,
          "session_id" => created.id,
          "room_id" => first.id,
          "day" => 1,
          "slot" => 1,
          "locked" => true
        })

      report = Readiness.report(ctx.term.id, ctx.plan.id)
      assert row(report, :locks).count == 1
      assert row(report, :unplaced).status == :ok
    end
  end
end
