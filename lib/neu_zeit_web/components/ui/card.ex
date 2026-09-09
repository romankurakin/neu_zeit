defmodule NeuZeitWeb.UI.Card do
  @moduledoc "A content container with optional header actions and footer."
  use NeuZeitWeb, :ui_component

  attr :title, :string, default: nil
  attr :subtitle, :string, default: nil
  attr :tag_name, :string, default: "section", values: ~w(section aside div)
  attr :title_tag, :string, default: "h2", values: ~w(h2 h3 h4)
  attr :size, :string, default: "sm", values: ~w(xs sm md lg)
  attr :class, :any, default: nil
  attr :rest, :global
  slot :header_actions
  slot :footer
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <.dynamic_tag tag_name={@tag_name} {@rest}
      class={["card card-border min-w-0 border-base-300 bg-base-100", card_size(@size), @class]}>
      <div :if={@title || @subtitle || @header_actions != []}
        class="card-body flex-none flex-row items-start justify-between gap-4 border-b border-base-300">
        <div :if={@title || @subtitle} class="min-w-0">
          <.dynamic_tag :if={@title} tag_name={@title_tag} class="type-heading break-words">{@title}</.dynamic_tag>
          <p :if={@subtitle} class="type-detail break-words">{@subtitle}</p>
        </div>
        <div :if={@header_actions != []} class="flex shrink-0 items-center gap-2">{render_slot(@header_actions)}</div>
      </div>
      <div class="card-body type-body gap-4">{render_slot(@inner_block)}</div>
      <div :if={@footer != []} class="card-body flex-none border-t border-base-300">
        <div class="card-actions">{render_slot(@footer)}</div>
      </div>
    </.dynamic_tag>
    """
  end

  defp card_size("xs"), do: "card-xs"
  defp card_size("sm"), do: "card-sm"
  defp card_size("md"), do: "card-md"
  defp card_size("lg"), do: "card-lg"
end
