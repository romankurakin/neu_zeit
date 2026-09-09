defmodule NeuZeitWeb.Stories.Button do
  use PhoenixStorybook.Story, :component
  def function, do: &NeuZeitWeb.CoreComponents.button/1

  def variations do
    [
      %Variation{id: :default, slots: ["Cancel"]},
      %Variation{id: :primary, attributes: %{variant: "primary"}, slots: ["Save"]},
      %Variation{id: :secondary, attributes: %{variant: "secondary"}, slots: ["Create a copy"]},
      %Variation{id: :outline, attributes: %{variant: "outline"}, slots: ["Export"]},
      %Variation{id: :ghost, attributes: %{variant: "ghost"}, slots: ["Refresh"]},
      %Variation{id: :destructive, attributes: %{variant: "destructive"}, slots: ["Delete"]},
      %Variation{id: :small, attributes: %{size: "sm"}, slots: ["Open"]},
      %Variation{
        id: :disabled,
        attributes: %{disabled: true, variant: "primary"},
        slots: ["Save"]
      },
      %Variation{
        id: :long_label,
        attributes: %{variant: "primary"},
        slots: ["Составить расписание"]
      }
    ]
  end
end
