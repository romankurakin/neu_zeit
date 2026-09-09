defmodule NeuZeitWeb.UI.PageHeader do
  @moduledoc "A page title and its actions."
  use NeuZeitWeb, :ui_component

  @doc """
  Page title, optional subtitle, and right-aligned actions.
  """
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  slot :status
  slot :actions

  def page_header(assigns) do
    ~H"""
    <header class="mb-4 flex flex-wrap items-start justify-between gap-4">
      <div class="min-w-0">
        <div class="flex flex-wrap items-center gap-2">
          <h1 class="type-display">{@title}</h1>
          {render_slot(@status)}
        </div>
        <p :if={@subtitle} class="mt-1 type-detail text-base-content">{@subtitle}</p>
      </div>
      <div :if={@actions != []} class="flex flex-wrap items-center gap-2">
        {render_slot(@actions)}
      </div>
    </header>
    """
  end
end
