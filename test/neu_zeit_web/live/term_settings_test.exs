defmodule NeuZeitWeb.TermSettingsTest do
  use NeuZeitWeb.ConnCase, async: false
  import NeuZeit.Fixtures
  alias NeuZeit.Catalog
  alias NeuZeit.Catalog.Workloads

  test "the term hour unit controls workload conversion and does not change other terms", %{
    conn: conn
  } do
    term = term_fixture()
    other = term_fixture()
    {:ok, view, _} = live(conn, ~p"/terms/#{term}/settings")
    view |> element("button", "Change for this term") |> render_click()
    view |> form("#term-settings", term: %{academic_hour_minutes: "0"}) |> render_submit()
    assert Catalog.get_term!(term.id).academic_hour_minutes == 45
    view |> form("#term-settings", term: %{academic_hour_minutes: "30"}) |> render_submit()
    assert Catalog.get_term!(term.id).academic_hour_minutes == 30
    assert Catalog.get_term!(other.id).academic_hour_minutes == 45

    component = component_fixture()
    teacher = teacher_fixture()
    cohort = cohort_fixture()

    attrs = %{
      course_component_id: component.id,
      teacher_id: teacher.id,
      cohort_ids: [cohort.id],
      week_mask: [1],
      automatic_weeks: true,
      contact_hours: "6",
      duration_slots: 1
    }

    assert {:ok, :saved} = Catalog.save_workload(term.id, nil, attrs)
    assert [row] = Catalog.list_workload(term.id)
    assert Workloads.series_count(row) == 2
    assert Decimal.equal?(Workloads.hours(row), Decimal.new(6))

    assert {:error, _} = Catalog.update_term(term, %{academic_hour_minutes: 45})
    assert [unchanged] = Catalog.list_workload(term.id)
    assert Workloads.series_count(unchanged) == 2
    assert Enum.map(row.sessions, & &1.id) == Enum.map(unchanged.sessions, & &1.id)
    assert Decimal.equal?(Workloads.hours(unchanged), Decimal.new(6))
  end
end
