defmodule NeuZeitWeb.UI.DetailsPanel do
  @moduledoc "Details for the selected record."
  use NeuZeitWeb, :ui_component
  import NeuZeitWeb.UI.Card

  @doc """
  Shows details and editing controls for the selected record beside its list or grid.
  """
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :on_close, :any, default: nil, doc: "phx-click handler for the close button"
  attr :class, :any, default: nil
  attr :rest, :global
  slot :actions
  slot :inner_block, required: true

  def details_panel(assigns) do
    ~H"""
    <.card
      tag_name="aside"
      title={@title}
      subtitle={@subtitle}
      class={["w-full motion-safe:enter", @class]}
      aria-label={@title}
      {@rest}
    >
      <:header_actions :if={@on_close}>
        <.button
          type="button"
          variant="ghost"
          class="btn-square"
          phx-click={@on_close}
          aria-label={gettext("Close")}
        >
          <.icon name="hero-x-mark" class="size-4" />
        </.button>
      </:header_actions>
      {render_slot(@inner_block)}
      <:footer :if={@actions != []}>{render_slot(@actions)}</:footer>
    </.card>
    """
  end
end
