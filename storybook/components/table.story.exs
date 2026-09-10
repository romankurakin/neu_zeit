defmodule NeuZeitWeb.Stories.Table do
  use PhoenixStorybook.Story, :example
  use Gettext, backend: NeuZeitWeb.Gettext
  import NeuZeitWeb.UI.Table, only: [table: 1]
  import NeuZeitWeb.UI.Status, only: [status_indicator: 1]
  import NeuZeitWeb.Scheduling.TeachingWeeks, only: [teaching_weeks: 1]
  alias NeuZeitWeb.Storybook.Fixtures

  @impl true
  def render(assigns) do
    ~H"""
    <.table id="sessions-table" rows={Fixtures.rows()} row_id={&"row-#{&1.code}-#{&1.kind}"}>
      <:col :let={row} label={gettext("Course")}>{row.code}</:col>
      <:col :let={row} label={gettext("Kind")}>{row.kind}</:col>
      <:col :let={row} label={gettext("Teacher")}>{row.teacher}</:col>
      <:col :let={row} label={gettext("Weeks")}>
        <.teaching_weeks weeks={row.weeks} total={15} />
      </:col>
      <:col :let={row} label={gettext("Status")}><.status_indicator status={row.status} /></:col>
    </.table>
    """
  end
end
