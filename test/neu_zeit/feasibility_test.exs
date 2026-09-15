defmodule NeuZeit.Planning.FeasibilityTest do
  use NeuZeit.DataCase, async: true

  alias NeuZeit.Catalog
  alias NeuZeit.Planning
  alias NeuZeit.Planning.Feasibility

  @grid NeuZeit.Config.grid!()
  @days length(@grid.days)
  @slots length(@grid.slots)

  setup do
    {:ok, term} =
      Catalog.create_term(%{
        "name" => "Wintersemester 2026/27",
        "starts_on" => "2026-09-07",
        "ends_on" => "2026-12-20"
      })

    {:ok, building} = Catalog.create_building(%{"name" => "Hauptgebäude"})
    rooms = for n <- 1..3, do: room(building, "10#{n}")
    {:ok, plan} = Planning.create_plan(%{"term_id" => term.id, "name" => "Entwurf 1"})
    {:ok, cohort} = Catalog.create_cohort(%{"name" => "WI-1"})

    %{term: term, building: building, rooms: rooms, plan: plan, cohort: cohort}
  end

  defp room(building, name) do
    {:ok, room} = Catalog.create_room(%{"building_id" => building.id, "name" => name})
    room
  end

  defp component(rooms, code \\ "INF110") do
    {:ok, course} = Catalog.create_course(%{"code" => code, "title" => code})

    {:ok, component} =
      Catalog.create_course_component(%{
        "course_id" => course.id,
        "kind" => "lecture",
        "allowed_room_ids" => Enum.map(rooms, & &1.id)
      })

    component
  end

  defp teacher(name) do
    {:ok, teacher} = Catalog.create_teacher(%{"name" => name})
    teacher
  end

  defp session(ctx, component, teacher, overrides \\ %{}) do
    {:ok, session} =
      NeuZeit.Fixtures.create_session(
        Map.merge(
          %{
            "term_id" => ctx.term.id,
            "course_component_id" => component.id,
            "teacher_id" => teacher.id,
            "week_mask" => [1, 2, 3],
            "duration_slots" => 1,
            "cohort_ids" => [ctx.cohort.id]
          },
          overrides
        )
      )

    Catalog.get_session!(session.id)
  end

  test "an unconstrained session may start anywhere in the grid", ctx do
    created = session(ctx, component(ctx.rooms), teacher("Anna Weber"))

    assert map_size(Feasibility.cells_for(created, ctx.plan.id)) == @days * @slots
  end

  test "a two-slot session cannot start where it would run off the end of the day", ctx do
    created =
      session(ctx, component(ctx.rooms), teacher("Anna Weber"), %{"duration_slots" => 2})

    starts = Feasibility.cells_for(created, ctx.plan.id) |> Map.keys()

    assert Enum.max(Enum.map(starts, &elem(&1, 1))) == @slots - 1
    assert map_size(Feasibility.cells_for(created, ctx.plan.id)) == @days * (@slots - 1)
  end

  test "a slot profile confines the session to its own starts", ctx do
    {:ok, profile} =
      Catalog.create_slot_profile(%{
        "term_id" => ctx.term.id,
        "name" => "DE_EARLY",
        "cells" => [%{"day" => 1, "slot" => 1}, %{"day" => 3, "slot" => 2}]
      })

    created =
      session(ctx, component(ctx.rooms), teacher("Anna Weber"), %{"slot_profile_id" => profile.id})

    assert Feasibility.cells_for(created, ctx.plan.id) |> Map.keys() |> Enum.sort() ==
             [{1, 1}, {3, 2}]
  end

  test "availability and profile intersect rather than either winning", ctx do
    {:ok, profile} =
      Catalog.create_slot_profile(%{
        "term_id" => ctx.term.id,
        "name" => "SAT",
        "cells" => for(slot <- 1..@slots, do: %{"day" => 6, "slot" => slot})
      })

    saturday = teacher("Marat Zhaksylykov")
    created = session(ctx, component(ctx.rooms), saturday, %{"slot_profile_id" => profile.id})

    {:ok, _} =
      Catalog.replace_teacher_availability(
        ctx.term.id,
        saturday.id,
        for(slot <- 1..3, do: %{"day" => 6, "slot" => slot})
      )

    reloaded = Catalog.get_session!(created.id)

    assert Feasibility.cells_for(reloaded, ctx.plan.id) |> Map.keys() |> Enum.sort() ==
             [{6, 1}, {6, 2}, {6, 3}]
  end

  describe "conflicts already on the board" do
    test "position assessment checks the full duration in the current term", ctx do
      other_term = NeuZeit.Fixtures.term_fixture()
      shared = teacher("Anna Weber")
      created = session(ctx, component(ctx.rooms), shared, %{"duration_slots" => 2})

      {:ok, _} =
        Catalog.replace_teacher_availability(ctx.term.id, shared.id, [
          %{day: 2, slot: 1},
          %{day: 2, slot: 2}
        ])

      {:ok, _} =
        Catalog.replace_teacher_availability(other_term.id, shared.id, [
          %{day: 1, slot: 1},
          %{day: 1, slot: 2},
          %{day: 2, slot: 3}
        ])

      created = Catalog.get_session!(created.id)

      assert Enum.all?(Feasibility.assess(created, ctx.plan.id, 2, 1), &(&1.errors == []))

      for {day, slot} <- [{1, 1}, {2, 2}],
          choice <- Feasibility.assess(created, ctx.plan.id, day, slot) do
        assert Enum.any?(choice.errors, &(&1.type == "teacher_unavailable"))
      end
    end

    test "other terms cannot extend availability, including a multi-slot session", ctx do
      other_term = NeuZeit.Fixtures.term_fixture()
      shared = teacher("Anna Weber")
      created = session(ctx, component(ctx.rooms), shared, %{"duration_slots" => 2})

      {:ok, _} =
        Catalog.replace_teacher_availability(ctx.term.id, shared.id, [
          %{day: 1, slot: 1},
          %{day: 1, slot: 2}
        ])

      {:ok, _} =
        Catalog.replace_teacher_availability(other_term.id, shared.id, [
          %{day: 1, slot: 3},
          %{day: 2, slot: 1},
          %{day: 2, slot: 2}
        ])

      created = Catalog.get_session!(created.id)
      assert Map.keys(Feasibility.cells_for(created, ctx.plan.id)) == [{1, 1}]

      {:ok, placement} =
        Planning.create_placement(%{
          plan_id: ctx.plan.id,
          session_id: created.id,
          room_id: hd(ctx.rooms).id,
          day: 1,
          slot: 1
        })

      assert Feasibility.explain(placement, ctx.plan.id).availability.cells == 2
    end

    test "other terms cannot restrict an unrestricted term", ctx do
      other_term = NeuZeit.Fixtures.term_fixture()
      shared = teacher("Anna Weber")
      created = session(ctx, component(ctx.rooms), shared)

      {:ok, _} =
        Catalog.replace_teacher_availability(other_term.id, shared.id, [%{day: 2, slot: 1}])

      created = Catalog.get_session!(created.id)
      assert map_size(Feasibility.cells_for(created, ctx.plan.id)) == @days * @slots

      {:ok, placement} =
        Planning.create_placement(%{
          plan_id: ctx.plan.id,
          session_id: created.id,
          room_id: hd(ctx.rooms).id,
          day: 1,
          slot: 1
        })

      assert Feasibility.explain(placement, ctx.plan.id).availability == nil
    end

    test "a teacher busy in overlapping weeks blocks that cell", ctx do
      shared = teacher("Anna Weber")
      first = session(ctx, component(ctx.rooms, "A"), shared)
      second = session(ctx, component(ctx.rooms, "B"), shared)

      before = map_size(Feasibility.cells_for(second, ctx.plan.id))

      {:ok, _} =
        Planning.create_placement(%{
          "plan_id" => ctx.plan.id,
          "session_id" => first.id,
          "room_id" => hd(ctx.rooms).id,
          "day" => 2,
          "slot" => 3
        })

      cells = Feasibility.cells_for(second, ctx.plan.id)

      refute Map.has_key?(cells, {2, 3})
      assert map_size(cells) == before - 1
    end

    test "disjoint week sets do not conflict", ctx do
      shared = teacher("Anna Weber")
      first = session(ctx, component(ctx.rooms, "A"), shared, %{"week_mask" => [1, 3]})
      second = session(ctx, component(ctx.rooms, "B"), shared, %{"week_mask" => [2, 4]})

      {:ok, _} =
        Planning.create_placement(%{
          "plan_id" => ctx.plan.id,
          "session_id" => first.id,
          "room_id" => hd(ctx.rooms).id,
          "day" => 2,
          "slot" => 3
        })

      # The same teacher and time are allowed when teaching weeks do not overlap.
      assert Map.has_key?(Feasibility.cells_for(second, ctx.plan.id), {2, 3})
    end

    test "a cell survives while any allowed room is still free", ctx do
      [first_room, second_room, third_room] = ctx.rooms
      component = component(ctx.rooms)
      {:ok, separate} = Catalog.create_cohort(%{"name" => "IT-1"})

      # Different teachers and different cohorts, so only room availability is
      # under test here.
      occupier = session(ctx, component, teacher("Anna Weber"))
      other = session(ctx, component, teacher("Erik Hoffmann"), %{"cohort_ids" => [separate.id]})

      {:ok, _} =
        Planning.create_placement(%{
          "plan_id" => ctx.plan.id,
          "session_id" => occupier.id,
          "room_id" => first_room.id,
          "day" => 2,
          "slot" => 3
        })

      cells = Feasibility.cells_for(other, ctx.plan.id)

      assert Enum.sort(cells[{2, 3}]) == Enum.sort([second_room.id, third_room.id])
    end

    test "a cell disappears once every allowed room is taken", ctx do
      [only_room] = [hd(ctx.rooms)]
      component = component([only_room])
      {:ok, separate} = Catalog.create_cohort(%{"name" => "IT-1"})

      occupier = session(ctx, component, teacher("Anna Weber"))
      other = session(ctx, component, teacher("Erik Hoffmann"), %{"cohort_ids" => [separate.id]})

      {:ok, _} =
        Planning.create_placement(%{
          "plan_id" => ctx.plan.id,
          "session_id" => occupier.id,
          "room_id" => only_room.id,
          "day" => 2,
          "slot" => 3
        })

      refute Map.has_key?(Feasibility.cells_for(other, ctx.plan.id), {2, 3})
    end

    test "a session's own placement does not block itself", ctx do
      created = session(ctx, component(ctx.rooms), teacher("Anna Weber"))

      {:ok, _} =
        Planning.create_placement(%{
          "plan_id" => ctx.plan.id,
          "session_id" => created.id,
          "room_id" => hd(ctx.rooms).id,
          "day" => 2,
          "slot" => 3
        })

      # Asking where a placed session could go must still include where it is.
      assert Map.has_key?(Feasibility.cells_for(created, ctx.plan.id), {2, 3})
    end
  end

  test "explain names the rules holding a placement in place", ctx do
    {:ok, profile} =
      Catalog.create_slot_profile(%{
        "term_id" => ctx.term.id,
        "name" => "DE_EARLY",
        "cells" => [%{"day" => 1, "slot" => 1}]
      })

    created =
      session(ctx, component(ctx.rooms), teacher("Anna Weber"), %{"slot_profile_id" => profile.id})

    {:ok, placement} =
      Planning.create_placement(%{
        "plan_id" => ctx.plan.id,
        "session_id" => created.id,
        "room_id" => hd(ctx.rooms).id,
        "day" => 1,
        "slot" => 1,
        "locked" => true
      })

    explanation =
      Feasibility.explain(Planning.get_placement!(placement.id), ctx.plan.id)

    assert explanation.locked
    assert explanation.slot_profile.name == "DE_EARLY"
    assert explanation.availability == nil
    assert length(explanation.room_pool.rooms) == 3
    assert explanation.alternatives == 1
  end
end
