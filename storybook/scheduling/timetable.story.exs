defmodule NeuZeitWeb.Stories.Timetable do
  use PhoenixStorybook.Story, :example
  use Gettext, backend: NeuZeitWeb.Gettext
  import NeuZeitWeb.Scheduling.Timetable, only: [timetable: 1]
  alias NeuZeitWeb.Storybook.Fixtures

  @impl true
  def render(assigns) do
    ~H"""
    <.timetable
      id="duration-board"
      placements={Fixtures.placements()}
      week={3}
      weeks_count={15}
      readonly
    />
    """
  end
end
