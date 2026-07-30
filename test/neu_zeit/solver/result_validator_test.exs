defmodule NeuZeit.Solver.ResultValidatorTest do
  use NeuZeit.DataCase, async: true

  import NeuZeit.Fixtures

  alias NeuZeit.Planning
  alias NeuZeit.Solver.{ResultValidator, SpecBuilder}

  test "rejects a solver result that moves a locked guest lecture" do
    term = term_fixture()
    room_a = room_fixture(name: "Guest-A")
    room_b = room_fixture(name: "Guest-B")
    component = component_fixture(rooms: [room_a, room_b])

    guest_session =
      session_fixture(
        term: term,
        component: component,
        teacher: teacher_fixture(name: "Guest lecturer"),
        cohorts: [cohort_fixture(name: "Guest cohort")],
        week_mask: [1, 2]
      )

    plan = plan_fixture(term: term)

    assert {:ok, _placement} =
             Planning.create_placement(%{
               plan_id: plan.id,
               session_id: guest_session.id,
               room_id: room_a.id,
               day: 2,
               slot: 2,
               locked: true
             })

    spec = SpecBuilder.build!(plan.id)

    result = %{
      "ok" => true,
      "status" => "OPTIMAL",
      "unplaced" => [],
      "assignment" => %{
        guest_session.id => %{"room" => room_b.id, "day" => 2, "slot" => 2}
      }
    }

    assert {:error,
            %{
              errors: [
                %{type: "locked_placement_moved", session_ids: [guest_session_id]}
              ]
            }} = ResultValidator.validate(plan.id, spec, result)

    assert guest_session_id == guest_session.id
  end

  test "rejects assignments that omit a required session" do
    term = term_fixture()
    room = room_fixture()
    component = component_fixture(rooms: [room])
    first = session_fixture(term: term, component: component)
    second = session_fixture(term: term, component: component)
    plan = plan_fixture(term: term)
    spec = SpecBuilder.build!(plan.id)

    result = %{
      "ok" => true,
      "status" => "OPTIMAL",
      "unplaced" => [],
      "assignment" => %{
        first.id => %{"room" => room.id, "day" => 1, "slot" => 1}
      }
    }

    assert {:error,
            %{
              errors: [
                %{type: "solver_assignment_mismatch", session_ids: [session_id]}
              ]
            }} = ResultValidator.validate(plan.id, spec, result)

    assert session_id == second.id
  end
end
