defmodule NeuZeitWeb.Stories.StatusIndicator do
  use PhoenixStorybook.Story, :component
  def function, do: &NeuZeitWeb.UI.Status.status_indicator/1

  def variations do
    for status <-
          ~w(draft active archived blocked error warning advisory ok info unknown under over)a,
        do: %Variation{id: status, attributes: %{status: status}}
  end
end
