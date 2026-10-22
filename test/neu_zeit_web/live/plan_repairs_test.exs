defmodule NeuZeitWeb.PlanRepairsTest do
  use NeuZeitWeb.ConnCase, async: true
  import NeuZeit.Fixtures
  alias NeuZeit.Planning

  setup do
    term = term_fixture()
    room = room_fixture()
    component = component_fixture(rooms: [room])
    selected = session_fixture(term: term, component: component)
    blocker = session_fixture(term: term, component: component)
    plan = plan_fixture(term: term)

    placement =
      placement_fixture(%{
        plan_id: plan.id,
        session_id: blocker.id,
        room_id: room.id,
        day: 1,
        slot: 1
      })

    %{term: term, selected: selected, blocker: blocker, plan: plan, placement: placement}
  end

  defp inspect_blocked_cell(c) do
    {:ok, view, _} = live(c.conn, ~p"/terms/#{c.term}/plans/#{c.plan}?session=#{c.selected.id}")
    view |> element("#board-cell-1-1 > button") |> render_click()
    render_async(view)
    view
  end

  defp positions(plan),
    do: Map.new(Planning.list_placements(plan.id), &{&1.session_id, {&1.day, &1.slot}})

  test "applies a suggested move and undoes it in one step", c do
    view = inspect_blocked_cell(c)

    assert has_element?(view, "#repair-0", c.blocker.teacher.name)
    view |> element("#repair-0 button", "Apply") |> render_click()

    placed = positions(c.plan)
    assert placed[c.selected.id] == {1, 1}
    assert placed[c.blocker.id] not in [nil, {1, 1}]

    view |> element("button[phx-click='undo']") |> render_click()
    assert positions(c.plan) == %{c.blocker.id => {1, 1}}
    assert has_element?(view, "button[phx-click='undo'][disabled]")
  end

  test "explains that a locked session blocks the start", c do
    {:ok, _} = Planning.update_placement(c.placement, %{"locked" => true})
    view = inspect_blocked_cell(c)

    assert has_element?(view, "#position-repairs", "does not free this start")
    refute has_element?(view, "#repair-0")
  end
end
