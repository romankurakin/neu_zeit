defmodule NeuZeitWeb.UI.Dates do
  @moduledoc """
  Dates in the reader's regional format, with timestamps in the institution's time zone.

  The language switcher sets the words of the interface. It does not say whether
  a reader expects 24.08.2026 or 08/24/2026, because that follows the region set
  in the browser. So the server sends the exact date and the browser formats it.

  `NeuZeitWeb.Layouts.app/1` carries the hook that does the formatting. Dates
  outside it, such as Storybook, stay in the ISO form the server rendered.
  """
  use NeuZeitWeb, :ui_component

  @doc """
  Renders one date or moment.

  The element keeps the ISO value in `datetime`, so the page reads correctly
  before the script runs and machines still get an exact value.

  Formats: `date` for a full date, `day_month` inside one term, where the year
  is already known, and `moment` for a date with the time of day.
  """
  attr :value, :any, required: true, doc: "%Date{}, %DateTime{}, or nil for nothing"
  attr :format, :string, default: "date", values: ~w(date day_month moment)
  attr :class, :any, default: nil

  def date(%{value: nil} = assigns), do: ~H""

  def date(assigns) do
    assigns = assign(assigns, :iso, iso(assigns.value))

    ~H"""
    <time datetime={@iso} data-format={@format} class={@class}>{@iso}</time>
    """
  end

  defp iso(%Date{} = value), do: Date.to_iso8601(value)
  defp iso(%DateTime{} = value), do: DateTime.to_iso8601(value)
end
