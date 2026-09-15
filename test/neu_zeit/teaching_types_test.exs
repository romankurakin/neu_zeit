defmodule NeuZeit.TeachingTypesTest do
  use NeuZeit.DataCase, async: true
  import NeuZeit.Fixtures
  alias NeuZeit.{Catalog, Planning}

  test "starter names are available in all three languages without creating courses" do
    assert Enum.sort(Enum.map(Catalog.list_teaching_types(), & &1.id)) ==
             ~w(exam lab lecture practical seminar)

    assert Catalog.list_courses() == []
    exam = Catalog.get_teaching_type!("exam")

    assert {label(exam, "en"), label(exam, "ru"), label(exam, "de")} ==
             {"Exam", "Экзамен", "Prüfung"}
  end

  test "custom types require one name and reject duplicate and overlong names" do
    assert {:error, _} = Catalog.create_teaching_type(%{names: %{"ru" => "  "}})

    assert {:error, _} =
             Catalog.create_teaching_type(%{names: %{"en" => String.duplicate("a", 101)}})

    assert {:ok, type} = Catalog.create_teaching_type(%{names: %{"ru" => "  Защита проекта  "}})
    assert label(type, "ru") == "Защита проекта"
    refute Enum.any?(type.translations, &(&1.locale == "en"))
    assert {:error, _} = Catalog.create_teaching_type(%{names: %{"en" => " lecture "}})
    assert {:error, _} = Catalog.update_teaching_type(type, %{names: %{"ru" => ""}})
  end

  test "new locales need no schema change and partial edits preserve hidden translations" do
    assert {:ok, type} =
             Catalog.create_teaching_type(%{names: %{"fr" => "Atelier", "ru" => "Мастерская"}})

    assert label(type, "fr") == "Atelier"
    assert {:ok, _} = Catalog.update_teaching_type(type, %{names: %{"ru" => "Практикум"}})
    # Reuse the original snapshot, as two open editors would.
    assert {:ok, updated} =
             Catalog.update_teaching_type(type, %{names: %{"fr" => "Atelier pratique"}})

    assert label(updated, "ru") == "Практикум"
    assert label(updated, "fr") == "Atelier pratique"
    assert {:ok, updated} = Catalog.update_teaching_type(updated, %{names: %{"fr" => ""}})
    assert Enum.map(updated.translations, & &1.locale) == ["ru"]
    assert {:error, _} = Catalog.update_teaching_type(updated, %{names: %{"ru" => ""}})
    assert {:error, _} = Catalog.create_teaching_type(%{names: %{"invalid locale" => "Studio"}})
    assert {:error, _} = Catalog.create_teaching_type(%{names: %{"fr" => %{bad: "value"}}})
  end

  test "renaming a used type preserves component and session identities", do: check_rename()

  defp check_rename do
    {:ok, type} = Catalog.create_teaching_type(%{names: %{"en" => "Project defence"}})
    session = session_fixture(component: component_fixture(kind: type.id))
    assert {:error, _} = Catalog.delete_teaching_type(type)

    assert {:ok, renamed} =
             Catalog.update_teaching_type(type, %{
               names: %{"en" => "Final project", "de" => "Projektabschluss"}
             })

    reloaded = Catalog.get_session!(session.id)
    assert renamed.id == type.id
    assert reloaded.course_component.id == session.course_component.id
    assert reloaded.course_component.kind == type.id
    assert label(reloaded.course_component.teaching_type, "de") == "Projektabschluss"
    assert reloaded.workload_id == session.workload_id
    [row] = Catalog.list_workload(session.term_id)
    assert {:ok, :deleted} = Catalog.delete_workload(session.term_id, row)
    assert {:ok, _} = Catalog.delete_course_component(reloaded.course_component)
    assert {:ok, _} = Catalog.delete_teaching_type(renamed)
  end

  test "a deleted starter is not recreated when listing types" do
    assert {:ok, _} = Catalog.delete_teaching_type(Catalog.get_teaching_type!("exam"))
    refute Enum.any?(Catalog.list_teaching_types(), &(&1.id == "exam"))

    assert {:error, _} =
             Catalog.create_course_component(%{
               course_id: course_fixture().id,
               kind: "exam",
               allowed_room_ids: [room_fixture().id]
             })
  end

  test "exam hours generate one meeting that can be placed and locked in the final week" do
    term = term_fixture()
    component = component_fixture(kind: "exam")

    assert {:ok, :saved} =
             Catalog.save_workload(term.id, nil, %{
               course_component_id: component.id,
               teacher_id: teacher_fixture().id,
               cohort_ids: [cohort_fixture().id],
               week_mask: [term.weeks_count],
               duration_slots: 2,
               contact_hours: "4"
             })

    assert [session] = Catalog.list_sessions(term.id)
    plan = plan_fixture(term: term)

    placement_fixture(
      plan_id: plan.id,
      session_id: session.id,
      room_id: hd(component.allowed_rooms).id,
      day: 1,
      slot: 1,
      week_mask: [term.weeks_count],
      locked: true
    )

    assert {:ok, _} = Planning.publish_plan(plan.id)
    assert [occurrence] = Planning.project_active_term(term.id).occurrences
    assert occurrence.date == Date.add(term.starts_on, (term.weeks_count - 1) * 7)
  end

  defp label(type, locale), do: NeuZeit.Catalog.Translation.text(type.translations, locale, :name)
end
