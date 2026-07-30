defmodule NeuZeit.Catalog.SlotProfileTest do
  use NeuZeit.DataCase, async: true

  import NeuZeit.Fixtures

  alias NeuZeit.Catalog
  alias NeuZeit.Planning

  test "creates the inferred DKU profiles idempotently" do
    term = term_fixture()

    assert {:ok, profiles} = Catalog.ensure_default_slot_profiles(term)

    assert Enum.map(profiles, & &1.name) == [
             "ANY",
             "DAYTIME_ANY",
             "DE_EARLY",
             "DE_LATE",
             "EN_EARLY",
             "EN_LATE",
             "EN_SATURDAY",
             "KZ_LATE",
             "PE_EDGE"
           ]

    de_early = Enum.find(profiles, &(&1.name == "DE_EARLY"))
    kz_late = Enum.find(profiles, &(&1.name == "KZ_LATE"))

    assert Enum.map(de_early.cells, &{&1.day, &1.slot}) == [
             {1, 1},
             {1, 2},
             {3, 1},
             {3, 2},
             {5, 1},
             {5, 2}
           ]

    assert Enum.all?(kz_late.cells, &(&1.day in 1..5 and &1.slot in 3..6))
    assert length(kz_late.cells) == 20

    assert {:ok, same_profiles} = Catalog.ensure_default_slot_profiles(term)
    assert length(same_profiles) == length(profiles)
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
             Catalog.create_session(%{
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
             Catalog.create_session(%{
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
