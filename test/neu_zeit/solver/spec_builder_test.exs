defmodule NeuZeit.Solver.SpecBuilderTest do
  use NeuZeit.DataCase, async: true

  import NeuZeit.Fixtures

  alias NeuZeit.Planning
  alias NeuZeit.Solver.SpecBuilder

  test "builds the solver contract from persisted scheduling data and policy defaults" do
    term = term_fixture(excluded_dates: [~D[2026-09-08]])
    building = building_fixture(name: "Main")
    room_a = room_fixture(building: building, name: "A-101")
    room_b = room_fixture(building: building, name: "A-102")
    component = component_fixture(rooms: [room_a, room_b])
    teacher = teacher_fixture()
    cohort = cohort_fixture()

    session =
      session_fixture(
        term: term,
        component: component,
        teacher: teacher,
        cohorts: [cohort],
        week_mask: [1, 2],
        sequence_group: "intro-lecture"
      )

    plan = plan_fixture(term: term)

    assert {:ok, _placement} =
             Planning.create_placement(%{
               plan_id: plan.id,
               session_id: session.id,
               room_id: room_b.id,
               day: 2,
               slot: 3,
               locked: true
             })

    spec = SpecBuilder.build!(plan.id)

    assert spec.grid == %{days_count: 6, slots_per_day: 6}
    assert spec.excluded_cells == [%{week: 2, day: 2}]
    assert spec.solver == %{time_limit: 180, gap: 0.01, workers: 8}
    assert spec.requirements == %{all_sessions_placed: true}

    assert spec.soft.weights == %{
             weekly_balance: 100,
             building: 10,
             gaps: 5,
             active_days: 2,
             sequence: 8,
             perturbation: 3,
             excluded_days: 10
           }

    room_ids = Enum.sort([to_string(room_a.id), to_string(room_b.id)])

    assert Enum.map(spec.rooms, & &1.id) == room_ids
    assert Enum.all?(spec.rooms, &(&1.building_id == to_string(building.id)))

    assert [
             %{
               id: session_id,
               teacher: teacher_id,
               cohorts: cohort_ids,
               allowed_rooms: allowed_rooms,
               allowed_starts: allowed_starts,
               duration_slots: 1,
               weeks: [1, 2],
               sequence_group: "intro-lecture"
             }
           ] = spec.sessions

    assert session_id == to_string(session.id)
    assert teacher_id == to_string(teacher.id)
    assert cohort_ids == [to_string(cohort.id)]
    assert Enum.sort(allowed_rooms) == room_ids
    assert length(allowed_starts) == 36

    placement = %{day: 2, slot: 3, room: to_string(room_b.id)}
    assert spec.fixed == %{to_string(session.id) => placement}
    assert spec.current == %{to_string(session.id) => placement}

    assert spec.hard.room_groups == []
    assert spec.hard.exclusive_groups == []
    assert spec.soft.building_groups == []
    assert spec.soft.gap_groups == []
    assert spec.soft.active_day_groups == []

    assert spec.soft.sequence_pairs == []
  end

  test "marks teaching cells after a partial final week as excluded" do
    term =
      term_fixture(
        starts_on: ~D[2026-08-31],
        ends_on: ~D[2026-09-09],
        excluded_dates: []
      )

    plan = plan_fixture(term: term)

    assert SpecBuilder.build!(plan.id).excluded_cells == [
             %{week: 2, day: 4},
             %{week: 2, day: 5},
             %{week: 2, day: 6}
           ]
  end

  test "excludes both partial boundaries and maps holidays to calendar weeks" do
    term =
      term_fixture(
        starts_on: ~D[2026-09-01],
        ends_on: ~D[2026-09-09],
        excluded_dates: [~D[2026-09-08]]
      )

    plan = plan_fixture(term: term)

    assert SpecBuilder.build!(plan.id).excluded_cells == [
             %{week: 1, day: 1},
             %{week: 2, day: 2},
             %{week: 2, day: 4},
             %{week: 2, day: 5},
             %{week: 2, day: 6}
           ]
  end

  test "combines boundaries when the entire term is a partial week" do
    term = term_fixture(starts_on: ~D[2026-09-02], ends_on: ~D[2026-09-04])
    plan = plan_fixture(term: term)

    assert SpecBuilder.build!(plan.id).excluded_cells == [
             %{week: 1, day: 1},
             %{week: 1, day: 2},
             %{week: 1, day: 6}
           ]
  end

  test "serializes duration and filters a profile to valid block starts" do
    term = term_fixture()

    profile =
      slot_profile_fixture(
        term: term,
        cells: [%{day: 1, slot: 2}, %{day: 1, slot: 6}, %{day: 6, slot: 3}]
      )

    session =
      session_fixture(
        term: term,
        duration_slots: 2,
        slot_profile_id: profile.id
      )

    plan = plan_fixture(term: term)
    assert [spec] = SpecBuilder.build!(plan.id).sessions
    assert spec.id == session.id
    assert spec.duration_slots == 2
    assert spec.allowed_starts == [%{day: 1, slot: 2}, %{day: 6, slot: 3}]
  end
end
