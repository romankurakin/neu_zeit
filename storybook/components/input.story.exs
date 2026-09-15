defmodule NeuZeitWeb.Stories.Input do
  use PhoenixStorybook.Story, :component

  def function, do: &NeuZeitWeb.CoreComponents.input/1
  def render_source, do: :function

  def variations do
    [
      %Variation{id: :name, attributes: %{name: "name", label: "Name", value: "Autumn 2026"}},
      %Variation{
        id: :invalid,
        attributes: %{
          name: "capacity",
          type: "number",
          label: "Seats",
          value: 0,
          errors: ["Must be greater than 0"]
        }
      }
    ]
  end
end
