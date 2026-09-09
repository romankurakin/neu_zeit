defmodule NeuZeitWeb.Stories.Select do
  use PhoenixStorybook.Story, :component
  def function, do: &NeuZeitWeb.CoreComponents.input/1

  def variations do
    [
      %Variation{
        id: :default,
        attributes: %{
          name: "select",
          type: "select",
          label: "Select",
          value: "101",
          options: [{"101", "101"}, {"L12", "L12"}]
        }
      },
      %Variation{
        id: :disabled,
        attributes: %{
          name: "select-disabled",
          type: "select",
          label: "Select",
          value: "101",
          options: [{"101", "101"}, {"L12", "L12"}],
          disabled: true
        }
      }
    ]
  end
end
