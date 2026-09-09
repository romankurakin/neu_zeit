defmodule NeuZeitWeb.Stories.LoadingState do
  use PhoenixStorybook.Story, :component
  def function, do: &NeuZeitWeb.UI.LoadingState.loading_state/1

  def variations do
    [
      %Variation{
        id: :calculation,
        attributes: %{label: "Generating timetable", elapsed_seconds: 42, limit_seconds: 180}
      },
      %Variation{
        id: :starting,
        attributes: %{label: "Generating timetable", elapsed_seconds: 0, limit_seconds: 180}
      }
    ]
  end
end
