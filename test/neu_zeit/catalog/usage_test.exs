defmodule NeuZeit.Catalog.UsageTest do
  use NeuZeit.DataCase, async: true
  import NeuZeit.Fixtures
  alias NeuZeit.{Catalog, Planning}

  describe "buildings" do
    test "usage counts rooms per building and a building with rooms is protected" do
      full = building_fixture()
      empty = building_fixture()
      room_fixture(building: full)
      room_fixture(building: full)

      assert Catalog.building_usage() == %{full.id => 2}

      assert {:error, changeset} = Catalog.delete_building(full)
      assert "This building has rooms. Delete or move its rooms first." in errors_on(changeset).id
      assert Catalog.get_building!(full.id)

      assert {:ok, _} = Catalog.delete_building(empty)
      assert Enum.map(Catalog.list_buildings(), & &1.id) == [full.id]
    end

    test "a building can be renamed" do
      building = building_fixture(name: "Old wing")
      assert {:ok, renamed} = Catalog.update_building(building, %{name: "New wing"})
      assert renamed.name == "New wing"
    end
  end

  describe "teachers" do
    test "one-off changes naming a substitute count as usage" do
      term = term_fixture()
      session = session_fixture(term: term, week_mask: [1, 2, 3])
      room = hd(session.course_component.allowed_rooms)
      plan = plan_fixture(term: term)

      placement_fixture(
        plan_id: plan.id,
        session_id: session.id,
        room_id: room.id,
        day: 1,
        slot: 1
      )

      {:ok, _plan} = Planning.publish_plan(plan.id)
      substitute = teacher_fixture()
      spare = teacher_fixture()

      {:ok, _exception} =
        Planning.create_schedule_exception(%{
          session_id: session.id,
          kind: "substitute",
          occurrence_date: ~D[2026-08-31],
          new_teacher_id: substitute.id,
          reason: "Cover",
          created_by: "Admin"
        })

      assert Catalog.teacher_exception_usage() == %{substitute.id => 1}
      refute Map.has_key?(Catalog.usage_counts().teachers, substitute.id)
      assert {:error, _changeset} = Catalog.delete_teacher(substitute)
      assert {:ok, _} = Catalog.delete_teacher(spare)
    end
  end
end
