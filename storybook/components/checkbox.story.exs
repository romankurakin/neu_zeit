defmodule NeuZeitWeb.Stories.Checkbox do
  use PhoenixStorybook.Story, :component
  def function, do: &NeuZeitWeb.CoreComponents.input/1

  def variations do
    [
      %Variation{
        id: :default,
        attributes: %{
          name: "checkbox",
          type: "checkbox",
          label: "Checkbox",
          value: false,
          checked: false
        }
      },
      %Variation{
        id: :disabled,
        attributes: %{
          name: "checkbox-disabled",
          type: "checkbox",
          label: "Checkbox",
          value: false,
          checked: false,
          disabled: true
        }
      }
    ]
  end
end
