defmodule NeuZeitWeb.Stories.PageHeader do
  use PhoenixStorybook.Story, :component
  def function, do: &NeuZeitWeb.UI.PageHeader.page_header/1

  def variations do
    [
      %Variation{id: :title, attributes: %{title: "Timetable"}},
      %Variation{
        id: :with_summary,
        attributes: %{title: "Autumn 2026", subtitle: "2 unplaced sessions"}
      }
    ]
  end
end
