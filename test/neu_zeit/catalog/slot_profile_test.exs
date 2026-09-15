defmodule NeuZeit.Catalog.SlotProfileTest do
  use NeuZeit.DataCase, async: true

  import NeuZeit.Fixtures

  alias NeuZeit.Catalog
  alias NeuZeit.Planning

  test "creates only the weekday daytime profile idempotently" do
    term = term_fixture()
    assert {:ok, [profile]} = Catalog.ensure_default_slot_profiles(term)
    assert profile.name == "Weekdays, daytime"
    assert profile.preset_key == "weekday_daytime"

    assert MapSet.new(profile.cells, &{&1.day, &1.slot}) ==
             MapSet.new(for day <- 1..5, slot <- 1..4, do: {day, slot})

    assert {:ok, [same]} = Catalog.ensure_default_slot_profiles(term)
    assert same.id == profile.id
  end

  test "reuses a matching example without changing its cells or name" do
    term = term_fixture()
    cells = for day <- 1..5, slot <- 1..4, do: %{day: day, slot: slot}
    existing = slot_profile_fixture(term: term, name: "Будни, дневное время", cells: cells)
    assert {:ok, [profile]} = Catalog.ensure_default_slot_profiles(term)
    assert profile.id == existing.id
    assert profile.name == existing.name
    assert profile.preset_key == "weekday_daytime"
  end

  test "does not treat a similarly named custom grid as the default" do
    term = term_fixture()

    custom =
      slot_profile_fixture(term: term, name: "Будни, дневное время", cells: [%{day: 6, slot: 1}])

    assert {:ok, profiles} = Catalog.ensure_default_slot_profiles(term)
    assert length(profiles) == 2
    assert Catalog.get_slot_profile!(custom.id).preset_key == nil
  end

  test "profile changes roll back when they invalidate an existing placement" do
    term = term_fixture()
    profile = slot_profile_fixture(term: term, cells: [%{day: 1, slot: 1}])
    room = room_fixture()
    component = component_fixture(rooms: [room])

    session =
      session_fixture(
        term: term,
        component: component,
        slot_profile_id: profile.id
      )

    plan = plan_fixture(term: term)

    placement_fixture(%{
      plan_id: plan.id,
      session_id: session.id,
      room_id: room.id,
      day: 1,
      slot: 1
    })

    assert {:error, %{errors: [%{type: "time_not_allowed"}]}} =
             Catalog.update_slot_profile(profile, %{cells: [%{day: 2, slot: 1}]})

    assert [{1, 1}] =
             profile.id
             |> Catalog.get_slot_profile!()
             |> Map.fetch!(:cells)
             |> Enum.map(&{&1.day, &1.slot})

    assert Planning.check_plan(plan.id) == []
  end

  test "a session cannot use a slot profile from another term" do
    term = term_fixture()
    other_profile = slot_profile_fixture(term: term_fixture())

    assert {:error, changeset} =
             NeuZeit.Fixtures.create_session(%{
               term_id: term.id,
               course_component_id: component_fixture().id,
               teacher_id: teacher_fixture().id,
               cohort_ids: [cohort_fixture().id],
               week_mask: [1],
               slot_profile_id: other_profile.id
             })

    assert %{slot_profile_id: [_message]} = errors_on(changeset)
  end

  test "a profile must contain a start that fits every assigned duration" do
    term = term_fixture()
    profile = slot_profile_fixture(term: term, cells: [%{day: 1, slot: 5}])

    session =
      session_fixture(
        term: term,
        slot_profile_id: profile.id,
        duration_slots: 2
      )

    assert {:error, changeset} =
             Catalog.update_slot_profile(profile, %{cells: [%{day: 1, slot: 6}]})

    assert %{cells: [_message]} = errors_on(changeset)
    assert Catalog.get_session!(session.id).duration_slots == 2

    impossible = slot_profile_fixture(term: term, cells: [%{day: 2, slot: 6}])

    assert {:error, changeset} =
             NeuZeit.Fixtures.create_session(%{
               term_id: term.id,
               course_component_id: component_fixture().id,
               teacher_id: teacher_fixture().id,
               cohort_ids: [cohort_fixture().id],
               week_mask: [1],
               duration_slots: 2,
               slot_profile_id: impossible.id
             })

    assert %{slot_profile_id: [_message]} = errors_on(changeset)
  end
end
