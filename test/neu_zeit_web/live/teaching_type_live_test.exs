defmodule NeuZeitWeb.TeachingTypeLiveTest do
  use NeuZeitWeb.ConnCase, async: true
  import NeuZeit.Fixtures
  alias NeuZeit.Catalog

  test "shows only the translation fields enabled in institution configuration" do
    form = Phoenix.Component.to_form(Catalog.change_teaching_type(%Catalog.TeachingType{}))

    for locale <- ~w(en ru de fr) do
      html =
        render_component(&NeuZeitWeb.TeachingTypeLive.Index.name_fields/1,
          form: form,
          locales: [locale]
        )

      assert html =~ "teaching_type[names][#{locale}]"

      for hidden <- ~w(en ru de fr) -- [locale],
          do: refute(html =~ "teaching_type[names][#{hidden}]")

      refute html =~ "If a translation is missing"
    end
  end

  test "creates a custom type in the registry and selects it in a course", %{conn: conn} do
    course = course_fixture()
    room = room_fixture()
    {:ok, view, _} = live(conn, ~p"/courses/#{course}")
    view |> element("a", "Manage teaching types") |> render_click()
    {path, _} = assert_redirect(view)
    {:ok, registry, _} = live(conn, path)
    registry |> element("a", "Add teaching type") |> render_click()

    registry
    |> form("#teaching-type-form",
      teaching_type: %{
        names: %{
          "en" => "Project defence",
          "ru" => "Защита проекта",
          "de" => "Projektverteidigung"
        }
      }
    )
    |> render_submit()

    type = Enum.find(Catalog.list_teaching_types(), &(label(&1, "en") == "Project defence"))
    assert has_element?(registry, "#teaching-type-#{type.id}", "Project defence")
    assert has_element?(registry, "a[href='/courses/#{course.id}']", "Return")
    {:ok, view, _} = live(conn, ~p"/courses/#{course}")
    assert has_element?(view, "option[value='#{type.id}']", "Project defence")

    view
    |> form("#add-component-form", %{"kind" => type.id, "room_ids" => [room.id]})
    |> render_submit()

    assert [component] = Catalog.get_course!(course.id).components
    assert component.kind == type.id
    assert Catalog.list_sessions() == []
  end

  test "names follow the interface language and missing translations use the saved name", %{
    conn: conn
  } do
    {:ok, type} = Catalog.create_teaching_type(%{names: %{"ru" => "Зачёт"}})
    component = component_fixture(kind: type.id)

    for {locale, exam_name} <- [{"ru", "Экзамен"}, {"de", "Prüfung"}, {"en", "Exam"}] do
      localized = Plug.Test.init_test_session(conn, %{"locale" => locale})
      {:ok, view, _} = live(localized, ~p"/teaching-types")
      assert has_element?(view, "#teaching-type-exam", exam_name)
      assert has_element?(view, "#teaching-type-#{type.id}", "Зачёт")
      {:ok, course, _} = live(localized, ~p"/courses/#{component.course_id}")
      assert has_element?(course, "#component-#{component.id}", "Зачёт")
    end
  end

  test "renames a used type and explains why it cannot be deleted", %{conn: conn} do
    {:ok, type} = Catalog.create_teaching_type(%{names: %{"en" => "Studio"}})
    component = component_fixture(kind: type.id)
    {:ok, view, _} = live(conn, ~p"/teaching-types/#{type.id}/edit")

    view
    |> form("#teaching-type-form", teaching_type: %{names: %{"en" => "Design studio"}})
    |> render_submit()

    assert has_element?(view, "#teaching-type-#{type.id}", "Design studio")
    view |> element("#teaching-type-#{type.id} button", "Delete") |> render_click()
    view |> element("#confirm-modal button", "Delete") |> render_click()
    assert render(view) =~ "used by courses"
    {:ok, course, _} = live(conn, ~p"/courses/#{component.course_id}")
    assert has_element?(course, "#component-#{component.id}", "Design studio")
  end

  test "names form reports empty and duplicate names without losing other translations", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/teaching-types/new")

    view
    |> form("#teaching-type-form", teaching_type: %{names: %{en: "", de: "", ru: ""}})
    |> render_submit()

    assert render(view) =~ "Enter a name in at least one language."

    view
    |> form("#teaching-type-form", teaching_type: %{names: %{en: "Lecture", de: "", ru: ""}})
    |> render_submit()

    assert render(view) =~ "This value is already used. Enter another one."
  end

  defp label(type, locale), do: NeuZeit.Catalog.Translation.text(type.translations, locale, :name)
end
