defmodule NeuZeitWeb.SettingsLiveTest do
  use NeuZeitWeb.ConnCase, async: false
  import NeuZeit.Fixtures
  alias NeuZeit.{Catalog, Settings}

  test "saved enabled languages control the switcher and every translation editor", %{conn: conn} do
    {:ok, _} = Settings.save(%{supported_locales: ["ru"], default_locale: "ru"})
    assert {:error, _} = Settings.save(%{supported_locales: ["ru"], default_locale: "en"})
    assert {:error, _} = Settings.save(%{supported_locales: [], default_locale: "ru"})

    {:ok, type} =
      Catalog.create_teaching_type(%{
        names: %{"en" => "Project", "ru" => "Проект", "de" => "Projekt"}
      })

    {:ok, view, _} = live(conn, ~p"/teaching-types/#{type.id}/edit")
    assert has_element?(view, "input[name='teaching_type[names][ru]']")
    refute has_element?(view, "input[name='teaching_type[names][en]']")
    refute has_element?(view, "#locale-switcher option[value='de']")

    view
    |> form("#teaching-type-form", teaching_type: %{names: %{ru: "Защита"}})
    |> render_submit()

    assert Enum.find(Catalog.get_teaching_type!(type.id).translations, &(&1.locale == "de")).name ==
             "Projekt"

    course = course_fixture()
    {:ok, view, _} = live(conn, ~p"/courses/#{course}")
    assert has_element?(view, "#translation-form option[value='ru']")
    refute has_element?(view, "#translation-form option[value='de']")
  end

  test "institution settings can be saved through the form", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/settings")
    assert has_element?(view, "a", "Manage teaching types")

    view
    |> form("#institution-settings",
      institution: %{
        name: "Example University",
        timezone: "Europe/Berlin",
        supported_locales: ["en"],
        default_locale: "en"
      }
    )
    |> render_submit()

    assert Settings.get().supported_locales == ["en"]
    assert Settings.get().name == "Example University"
    assert Settings.get().timezone == "Europe/Berlin"
    assert {:error, _} = Settings.save(%{timezone: "Invalid/Zone"})
  end

  test "term grid editor starts collapsed, saves one term and protects it after workload entry",
       %{conn: conn} do
    term = term_fixture()
    {:ok, view, _} = live(conn, ~p"/terms/#{term}/settings")
    refute has_element?(view, "#term-settings")
    view |> element("button", "Change for this term") |> render_click()

    view
    |> form("#term-settings",
      term: %{teaching_days: "5", grid: %{slots: %{"0" => %{start: "08:10", end: "09:40"}}}}
    )
    |> render_submit()

    assert hd(Catalog.get_term!(term.id).grid.slots).start == "08:10"
    assert length(Catalog.get_term!(term.id).grid.days) == 5
    session_fixture(term: Catalog.get_term!(term.id))
    {:ok, view, _} = live(conn, ~p"/terms/#{term}/settings")
    refute has_element?(view, "button", "Change for this term")
    render_click(view, "save", %{"term" => %{"academic_hour_minutes" => "60"}})
    assert Catalog.get_term!(term.id).academic_hour_minutes == 45
  end
end
