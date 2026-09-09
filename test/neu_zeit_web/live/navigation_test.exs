defmodule NeuZeitWeb.NavigationTest do
  use NeuZeitWeb.ConnCase, async: true

  alias NeuZeit.{Catalog, Planning}

  defp term(name) do
    {:ok, term} =
      Catalog.create_term(%{
        "name" => name,
        "starts_on" => "2026-09-07",
        "ends_on" => "2026-12-20"
      })

    term
  end

  test "navigation keeps all workflow groups without a term", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/rooms")

    for heading <- ["Term", "Preparation", "Scheduling"] do
      assert has_element?(view, "#main-navigation .menu-title", heading)
    end

    assert has_element?(view, "#main-navigation [aria-disabled=true]", "Plans")
    assert has_element?(view, "#main-navigation a[href='/rooms'][aria-current=page]")
  end

  test "registries retain the selected term and active item", %{conn: conn} do
    selected = term("A selected")
    term("Z other")
    path = NeuZeitWeb.Nav.with_return("/rooms", "/terms/#{selected.id}/plans")
    {:ok, view, _html} = live(conn, path)
    assert has_element?(view, "#term-switcher option[value='#{selected.id}'][selected]")
    assert has_element?(view, "#main-navigation a[href='/terms/#{selected.id}/plans']")
    assert has_element?(view, "#main-navigation a[aria-current=page]", "Rooms")
    view |> element("a", "New room") |> render_click()
    assert has_element?(view, "#main-navigation a[href='/terms/#{selected.id}/plans']")
  end

  test "the browser term survives a direct registry navigation", %{conn: conn} do
    selected = term("A selected")
    other = term("Z other")
    conn = put_connect_params(conn, %{"navigation_term" => selected.id})
    {:ok, view, _html} = live(conn, "/people")
    assert has_element?(view, "#term-switcher option[value='#{selected.id}'][selected]")
    view |> form("#term-switcher-form", term_id: other.id) |> render_change()
    assert_redirect(view, "/terms/#{other.id}")
  end

  test "switching terms stays in the same scheduling section", %{conn: conn} do
    selected = term("A selected")
    other = term("Z other")
    {:ok, view, _html} = live(conn, "/terms/#{selected.id}/plans")
    view |> form("#term-switcher-form", term_id: other.id) |> render_change()
    assert_redirect(view, "/terms/#{other.id}/plans")
  end

  test "stale browser selection falls back to an existing term", %{conn: conn} do
    selected = term("Current")
    conn = put_connect_params(conn, %{"navigation_term" => Ecto.UUID.generate()})
    {:ok, view, _html} = live(conn, "/courses")
    assert has_element?(view, "#term-switcher option[value='#{selected.id}'][selected]")
  end

  test "the plan and calendar retain the desktop sidebar", %{conn: conn} do
    term = term("Current")
    {:ok, plan} = Planning.create_plan(%{"term_id" => term.id, "name" => "Working"})

    for path <- ["/terms/#{term.id}/plans/#{plan.id}", "/terms/#{term.id}/calendar"] do
      {:ok, view, _html} = live(conn, path)
      assert has_element?(view, ~s{#app-drawer[class~="lg:drawer-open"]})
      assert has_element?(view, "#main-navigation a[href='/terms/#{term.id}/workload']")
    end
  end
end
