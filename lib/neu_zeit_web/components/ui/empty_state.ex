defmodule NeuZeitWeb.UI.EmptyState do
  @moduledoc "An empty collection and its next action."
  use NeuZeitWeb, :ui_component

  @doc """
  Shows an empty state and an optional next action.
  """
  attr :title, :string, required: true
  attr :message, :string, default: nil
  attr :icon, :string, default: "hero-inbox"
  slot :actions

  def empty_state(assigns) do
    ~H"""
    <div class="card card-dash items-center gap-4 border-base-300 bg-base-100 p-6 text-center">
      <.icon name={@icon} class="size-10 text-base-content" />
      <div>
        <p class="type-heading">{@title}</p>
        <p :if={@message} class="mt-1 type-detail text-base-content">{@message}</p>
      </div>
      <div :if={@actions != []} class="card-actions">{render_slot(@actions)}</div>
    </div>
    """
  end
end
