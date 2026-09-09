defmodule NeuZeitWeb.Stories.StatCard do
  use PhoenixStorybook.Story, :component
  def function, do: &NeuZeitWeb.UI.StatCard.stat_card/1

  def variations do
    [
      %Variation{id: :sessions, attributes: %{label: "Sessions", value: "46"}},
      %Variation{id: :unplaced, attributes: %{label: "Unplaced", value: "46", status: :warning}},
      %Variation{id: :conflicts, attributes: %{label: "Conflicts", value: "0", status: :ok}}
    ]
  end
end
