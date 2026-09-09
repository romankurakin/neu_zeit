defmodule NeuZeitWeb.UI.StatCard do
  @moduledoc "A labelled number with optional context."
  use NeuZeitWeb, :ui_component
  import NeuZeitWeb.UI.Card

  @doc """
  A single headline figure.
  """
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :hint, :string, default: nil
  attr :status, :any, default: nil, doc: "tints the value through the status vocabulary"

  def stat_card(assigns) do
    ~H"""
    <.card tag_name="div">
      <dl class="stat p-0">
      <dt class="stat-title type-detail">{@label}</dt>
      <dd class={["stat-value type-display tabular-nums", NeuZeitWeb.UI.Status.value_tone(@status)]}>{@value}</dd>
      <dd :if={@hint} class="stat-desc type-detail">{@hint}</dd>
      </dl>
    </.card>
    """
  end
end
