defmodule NeuZeitWeb.Stories.TimeField do
  use PhoenixStorybook.Story, :component

  def function, do: &NeuZeitWeb.UI.TimeField.time_field/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :start,
        attributes: %{name: "starts_at", label: "Start time", value: "08:00"}
      },
      %Variation{
        id: :empty,
        attributes: %{name: "ends_at", label: "End time", value: nil}
      },
      %Variation{
        id: :disabled,
        attributes: %{name: "fixed_time", label: "Fixed time", value: "09:30", disabled: true}
      }
    ]
  end
end
