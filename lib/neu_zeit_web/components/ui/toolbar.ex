defmodule NeuZeitWeb.UI.Toolbar do
  @moduledoc "Groups controls and actions for a view."
  use NeuZeitWeb, :ui_component

  @doc """
  Aligns page-specific filters and actions in a shared row.
  """
  attr :class, :any, default: nil
  slot :inner_block, required: true
  slot :actions

  def toolbar(assigns) do
    ~H"""
    <div class={[
      "mb-4 flex flex-wrap items-center gap-2 rounded-box border border-base-300 bg-base-100 px-3 py-2",
      @class
    ]}>
      {render_slot(@inner_block)}
      <div :if={@actions != []} class="ml-auto flex items-center gap-2">{render_slot(@actions)}</div>
    </div>
    """
  end
end
