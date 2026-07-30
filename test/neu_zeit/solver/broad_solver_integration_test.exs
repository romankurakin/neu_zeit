defmodule NeuZeit.Solver.BroadSolverIntegrationTest do
  use NeuZeit.DataCase, async: false

  import NeuZeit.Fixtures

  alias NeuZeit.Planning

  test "solves a multi-cohort term with room restrictions, sequence groups, and a locked guest lecture" do
    term = term_fixture()

    main = building_fixture(name: "Main Campus")
    science = building_fixture(name: "Science Block")
    annex = building_fixture(name: "Annex")

    auditorium = room_fixture(building: main, name: "Auditorium")
    seminar_room = room_fixture(building: main, name: "Seminar 204")
    lab = room_fixture(building: science, name: "Computer Lab")
    studio = room_fixture(building: annex, name: "Studio")

    cs_a = cohort_fixture(name: "CS-A")
    cs_b = cohort_fixture(name: "CS-B")
    se_a = cohort_fixture(name: "SE-A")
    data_a = cohort_fixture(name: "DATA-A")

    professor_ada = teacher_fixture(name: "Prof. Ada")
    professor_grace = teacher_fixture(name: "Prof. Grace")
    professor_donald = teacher_fixture(name: "Prof. Donald")
    guest = teacher_fixture(name: "Dr. Guest")

    algorithms =
      component_fixture(
        course: course_fixture(code: "ALG-301"),
        rooms: [auditorium, seminar_room]
      )

    databases = component_fixture(course: course_fixture(code: "DB-220"), rooms: [lab])

    networks =
      component_fixture(course: course_fixture(code: "NET-240"), rooms: [seminar_room, studio])

    statistics =
      component_fixture(
        course: course_fixture(code: "STAT-210"),
        rooms: [auditorium, seminar_room]
      )

    guest_component =
      component_fixture(course: course_fixture(code: "GUEST-101"), rooms: [auditorium])

    sessions = [
      session_fixture(
        term: term,
        component: algorithms,
        teacher: professor_ada,
        cohorts: [cs_a, cs_b],
        week_mask: Enum.to_list(1..16)
      ),
      session_fixture(
        term: term,
        component: algorithms,
        teacher: professor_ada,
        cohorts: [cs_a],
        week_mask: Enum.filter(1..16, &(rem(&1, 2) == 1)),
        sequence_group: "algorithms-double"
      ),
      session_fixture(
        term: term,
        component: algorithms,
        teacher: professor_ada,
        cohorts: [cs_a],
        week_mask: Enum.filter(1..16, &(rem(&1, 2) == 1)),
        sequence_group: "algorithms-double"
      ),
      session_fixture(
        term: term,
        component: databases,
        teacher: professor_grace,
        cohorts: [cs_a],
        week_mask: Enum.to_list(1..16)
      ),
      session_fixture(
        term: term,
        component: databases,
        teacher: professor_grace,
        cohorts: [cs_b],
        week_mask: Enum.to_list(1..16)
      ),
      session_fixture(
        term: term,
        component: networks,
        teacher: professor_donald,
        cohorts: [se_a],
        week_mask: Enum.to_list(1..16)
      ),
      session_fixture(
        term: term,
        component: networks,
        teacher: professor_donald,
        cohorts: [se_a],
        week_mask: Enum.filter(1..16, &(rem(&1, 2) == 0)),
        sequence_group: "networks-double"
      ),
      session_fixture(
        term: term,
        component: networks,
        teacher: professor_donald,
        cohorts: [se_a],
        week_mask: Enum.filter(1..16, &(rem(&1, 2) == 0)),
        sequence_group: "networks-double"
      ),
      session_fixture(
        term: term,
        component: statistics,
        teacher: professor_grace,
        cohorts: [data_a],
        week_mask: Enum.to_list(1..16)
      ),
      session_fixture(
        term: term,
        component: guest_component,
        teacher: guest,
        cohorts: [cs_a, se_a],
        week_mask: [5, 6]
      )
    ]

    plan = plan_fixture(term: term)
    guest_session = List.last(sessions)

    assert {:ok, _locked_placement} =
             Planning.create_placement(%{
               plan_id: plan.id,
               session_id: guest_session.id,
               room_id: auditorium.id,
               day: 3,
               slot: 2,
               locked: true
             })

    assert {:ok, result} = Planning.solve_plan(plan.id)
    assert result["status"] in ["OPTIMAL", "FEASIBLE"]
    assert result["unplaced"] == []

    placements = Planning.list_placements() |> Enum.filter(&(&1.plan_id == plan.id))
    assert length(placements) == length(sessions)
    assert Planning.check_plan(plan.id) == []

    locked = Enum.find(placements, &(&1.session_id == guest_session.id))
    assert locked.locked
    assert {locked.day, locked.slot, locked.room_id} == {3, 2, auditorium.id}
  end
end
