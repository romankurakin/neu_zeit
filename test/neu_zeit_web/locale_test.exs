defmodule NeuZeitWeb.LocaleTest do
  use NeuZeitWeb.ConnCase, async: true

  alias NeuZeitWeb.Locale

  test "offers exactly the languages institution policy declares" do
    assert Locale.supported() == NeuZeit.Config.load!().institution.supported_locales
    assert Locale.default() == NeuZeit.Config.load!().institution.default_locale
  end

  test "falls back to the institution default for an unknown language", %{conn: conn} do
    conn = conn |> Plug.Test.init_test_session(%{"locale" => "klingon"}) |> get(~p"/terms")
    assert get_session(conn, "locale") == Locale.default()
  end

  test "with no choice made, the institution default is used" do
    conn = Phoenix.ConnTest.build_conn() |> get(~p"/terms")
    assert get_session(conn, "locale") == Locale.default()
  end

  describe "switching" do
    test "stores the choice and returns to where it came from", %{conn: conn} do
      conn = post(conn, ~p"/locale", %{"locale" => "ru", "return_to" => "/rooms"})

      assert redirected_to(conn) == "/rooms"
      assert get_session(conn, "locale") == "ru"
    end

    test "ignores a language the institution does not offer", %{conn: conn} do
      conn = post(conn, ~p"/locale", %{"locale" => "klingon", "return_to" => "/rooms"})
      assert get_session(conn, "locale") == Locale.default()
    end

    test "never redirects off-site", %{conn: conn} do
      conn =
        post(conn, ~p"/locale", %{"locale" => "ru", "return_to" => "https://elsewhere.example"})

      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "catalogues" do
    # Gettext merge can copy an unreviewed translation and mark it fuzzy.
    # Require reviewed translations in every catalogue.
    test "carry no fuzzy translations" do
      for path <- catalogue_paths() do
        refute File.read!(path) =~ ~r/^#,.*\bfuzzy\b/m,
               "#{path} contains a fuzzy translation; review it and drop the marker"
      end
    end

    test "are complete for every supported language" do
      for path <- catalogue_paths() do
        untranslated =
          path
          |> File.read!()
          |> String.split("\n\n")
          |> Enum.filter(fn block ->
            block =~ ~r/^msgid "(?!")/m and
              (block =~ ~r/^msgstr ""$/m or block =~ ~r/^msgstr\[\d+\] ""$/m)
          end)

        assert untranslated == [], "#{path} has #{length(untranslated)} untranslated messages"
      end
    end

    defp catalogue_paths do
      for locale <- Locale.supported(),
          domain <- ~w(default errors),
          path = "priv/gettext/#{locale}/LC_MESSAGES/#{domain}.po",
          File.exists?(path),
          do: path
    end
  end

  describe "rendering" do
    @tag locale: "ru"
    test "calendar weekday labels are localized without changing their dates", %{conn: conn} do
      term = NeuZeit.Fixtures.term_fixture(%{starts_on: ~D[2026-09-07]})
      {:ok, view, _html} = live(conn, ~p"/terms/#{term}")

      assert has_element?(view, "th", "Пн")
      assert has_element?(view, "th", "Сб")
      refute has_element?(view, "th", "Mon")
      assert has_element?(view, "button[phx-value-date='#{term.starts_on}']", "07.09")
    end

    @tag locale: "ru"
    test "a LiveView renders in the session language", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/rooms")

      assert html =~ "Аудитории"
      refute html =~ "Buildings"
    end

    @tag locale: "de"
    test "German uses its own plural forms", %{conn: conn} do
      {:ok, building} = NeuZeit.Catalog.create_building(%{"name" => "Hauptgebäude"})
      {:ok, _room} = NeuZeit.Catalog.create_room(%{"building_id" => building.id, "name" => "101"})

      {:ok, _live, html} = live(conn, ~p"/rooms")
      assert html =~ "1 Raum"
    end

    @tag locale: "ru"
    test "Russian selects the right form of three", %{conn: conn} do
      {:ok, building} = NeuZeit.Catalog.create_building(%{"name" => "Главный"})

      for n <- 1..5 do
        {:ok, _} =
          NeuZeit.Catalog.create_room(%{"building_id" => building.id, "name" => "10#{n}"})
      end

      {:ok, _live, html} = live(conn, ~p"/rooms")
      assert html =~ "5 аудиторий"
    end
  end
end
