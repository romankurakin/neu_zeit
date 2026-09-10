defmodule NeuZeitWeb.StorybookTest do
  @moduledoc """
  Tests server handling of component events.

  `render_hook` supplies drag payloads directly. These tests do not verify
  SortableJS or pointer interactions in a browser.
  """
  use NeuZeitWeb.ConnCase, async: true

  defp story(conn, path) do
    {:ok, page, _html} = live(conn, "/dev/storybook/" <> path)

    case live_children(page) do
      [example] -> example
      [] -> page
    end
  end

  test "renders every status in the vocabulary", %{conn: conn} do
    html = render(story(conn, "components/status_indicator"))

    for label <- ["Draft", "Active", "Archived", "Blocked", "Conflict", "Warning"] do
      assert html =~ label
    end
  end

  describe "time grid" do
    test "painting adds the cells it covers", %{conn: conn} do
      live = story(conn, "scheduling/time_grid")

      html =
        render_hook(live, "grid_changed", %{
          "cells" => [%{"day" => 2, "slot" => 3}, %{"day" => 2, "slot" => 4}],
          "selected" => true
        })

      assert html =~ "5 selected time slots"
    end

    test "painting clears the cells it covers", %{conn: conn} do
      html =
        render_hook(story(conn, "scheduling/time_grid"), "grid_changed", %{
          "cells" => [%{"day" => 1, "slot" => 1}, %{"day" => 1, "slot" => 2}],
          "selected" => false
        })

      assert html =~ "1 selected time slot"
    end

    test "clicking a selected cell clears it", %{conn: conn} do
      html =
        story(conn, "scheduling/time_grid")
        |> element(~s{#availability-grid [data-cell][data-day="1"][data-slot="1"]})
        |> render_click()

      assert html =~ "2 selected time slots"
    end
  end

  describe "transfer list" do
    test "moving an item across updates the selected rooms", %{conn: conn} do
      live = story(conn, "components/transfer_list")

      html =
        render_hook(live, "selection_changed", %{
          "id" => "room-selection",
          "selected" => ["101", "102", "L12"]
        })

      assert has_element?(live, ~s{[data-role="selected"] [data-id="L12"]})
      refute html =~ "3 allowed rooms"
    end

    test "one allowed room is a valid selection", %{conn: conn} do
      live = story(conn, "components/transfer_list")

      render_hook(live, "selection_changed", %{
        "id" => "room-selection",
        "selected" => ["101"]
      })

      assert has_element?(live, ~s{#room-selection [data-role="selected"] [data-id="101"]})
      refute has_element?(live, "#room-selection .badge-warning")
    end
  end

  test "week picker moves through the term", %{conn: conn} do
    live = story(conn, "scheduling/week_picker")
    assert render(live) =~ "Week 3 of 15"

    html = live |> element(~s{button[phx-value-week="15"]}, "Last") |> render_click()
    assert html =~ "Week 15 of 15"
  end

  test "week picker keeps both arrows at the boundaries", %{conn: conn} do
    live = story(conn, "scheduling/week_picker")
    live |> element("button", "First") |> render_click()
    assert has_element?(live, ~s{button[aria-label="Previous week"][disabled]})
    assert has_element?(live, ~s{button[aria-label="Next week"]:not([disabled])})
    live |> element("button", "Last") |> render_click()
    assert has_element?(live, ~s{button[aria-label="Previous week"]:not([disabled])})
    assert has_element?(live, ~s{button[aria-label="Next week"][disabled]})
  end

  test "details panel closes and can be reopened", %{conn: conn} do
    live = story(conn, "components/details_panel")
    live |> element(~s{button[aria-label="Close"]}) |> render_click()
    refute has_element?(live, "aside")
    live |> element("button", "Open") |> render_click()
    assert has_element?(live, "aside")
  end

  test "filter reset restores every control", %{conn: conn} do
    live = story(conn, "components/toolbar")
    live |> element("form") |> render_change(%{"teacher" => "anna", "unplaced" => "true"})
    assert has_element?(live, ~s{option[value="anna"][selected]})
    assert has_element?(live, ~s{input[type="checkbox"][checked]})
    live |> element("button", "Reset filters") |> render_click()
    assert has_element?(live, ~s{option[value=""][selected]})
    refute has_element?(live, ~s{input[type="checkbox"][checked]})
  end

  describe "confirmation" do
    test "is not rendered until an action asks for it", %{conn: conn} do
      live = story(conn, "components/alert_dialog")
      refute has_element?(live, "#confirm-modal")
    end

    test "cancelling leaves no trace", %{conn: conn} do
      live = story(conn, "components/alert_dialog")
      live |> element(~s{button}, "Publish plan") |> render_click()
      assert has_element?(live, "#confirm-modal")

      live |> element(~s{#confirm-modal button}, "Cancel") |> render_click()
      refute has_element?(live, "#confirm-modal")
    end

    test "confirming closes it and reports back", %{conn: conn} do
      live = story(conn, "components/alert_dialog")
      live |> element(~s{button}, "Publish plan") |> render_click()
      html = live |> element(~s{#confirm-modal button}, "Publish plan") |> render_click()

      refute has_element?(live, "#confirm-modal")
      assert html =~ "Publication confirmed."
    end
  end

  test "context errors reach the user through the shared contract", %{conn: conn} do
    live = story(conn, "components/flash")
    html = live |> element(~s{button}, "Show an error") |> render_click()
    assert html =~ "Room occupied in weeks 3-8."
  end

  test "the application gallery route is removed" do
    refute Enum.any?(NeuZeitWeb.Router.__routes__(), &(&1.path == "/ui"))
  end

  test "card footer submits its associated form", %{conn: conn} do
    view = story(conn, "components/card")
    view |> element("button", "Edit") |> render_click()
    assert has_element?(view, ~s{button[type="submit"][form="card-name-form"]})
    view |> form("#card-name-form", name: "Maria Klein") |> render_submit()
    assert render(view) =~ "Maria Klein"
    refute has_element?(view, "#card-name-form")
  end

  test "dialog edits data and closes after saving", %{conn: conn} do
    view = story(conn, "components/dialog")
    view |> element("button", "Edit teacher") |> render_click()
    assert has_element?(view, ~s{dialog[aria-labelledby="teacher-dialog-title"]})
    assert has_element?(view, ~s{button[form="dialog-name-form"]})
    view |> form("#dialog-name-form", name: "Maria Klein") |> render_submit()
    assert render(view) =~ "Maria Klein"
    refute has_element?(view, "dialog")
  end

  test "tabs follow the current URL", %{conn: conn} do
    view = story(conn, "components/tabs")
    assert has_element?(view, ~s{nav[aria-label="People"] a[aria-current="page"]}, "Teachers")
    view |> element(~s{nav[aria-label="People"] a}, "Groups") |> render_click()
    assert_patch(view, "/dev/storybook/components/tabs?tab=groups")
    assert has_element?(view, ~s{nav[aria-label="People"] a[aria-current="page"]}, "Groups")
    assert render(view) =~ "WI-26-01"
  end

  test "every story renders without administrator navigation", %{conn: conn} do
    for entry <- NeuZeitWeb.Storybook.leaves() do
      {:ok, _view, html} = live(conn, "/dev/storybook" <> entry.path)
      refute html =~ "switch_term"
      refute html =~ "Application navigation"
    end
  end
end
