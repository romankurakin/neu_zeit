defmodule NeuZeitWeb.Stories.Textarea do
  use PhoenixStorybook.Story, :component
  def function, do: &NeuZeitWeb.CoreComponents.input/1

  def variations do
    [
      %Variation{
        id: :default,
        attributes: %{
          name: "textarea",
          type: "textarea",
          label: "Textarea",
          value: "Teacher available after 12:20."
        }
      },
      %Variation{
        id: :disabled,
        attributes: %{
          name: "textarea-disabled",
          type: "textarea",
          label: "Textarea",
          value: "Teacher available after 12:20.",
          disabled: true
        }
      }
    ]
  end
end
