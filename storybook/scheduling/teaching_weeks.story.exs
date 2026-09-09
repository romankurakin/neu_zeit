defmodule NeuZeitWeb.Stories.TeachingWeeks do
  use PhoenixStorybook.Story, :component
  def function, do: &NeuZeitWeb.Scheduling.TeachingWeeks.teaching_weeks/1

  def variations do
    [
      %Variation{id: :empty, attributes: %{weeks: [], total: 15}},
      %Variation{id: :single, attributes: %{weeks: [3], total: 15}},
      %Variation{
        id: :compact,
        attributes: %{weeks: [1, 2, 3, 12, 13, 14, 15], total: 15, compact: true}
      },
      %Variation{id: :every_week, attributes: %{weeks: Enum.to_list(1..15), total: 15}},
      %Variation{id: :odd_weeks, attributes: %{weeks: Enum.to_list(1..15//2), total: 15}},
      %Variation{id: :split_range, attributes: %{weeks: [1, 2, 3, 12, 13, 14, 15], total: 15}}
    ]
  end
end
