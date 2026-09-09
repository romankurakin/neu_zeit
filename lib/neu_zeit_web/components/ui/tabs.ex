defmodule NeuZeitWeb.UI.Tabs do
  @moduledoc "Navigation between views of the same resource."
  use NeuZeitWeb, :ui_component

  @doc """
  Renders tabs as URL patches. The selected tab survives reload and can be linked directly.
  """
  attr :items, :list, required: true, doc: "list of %{label:, path:} and optional :badge"
  attr :active, :string, required: true, doc: "path of the active tab"
  attr :label, :string, default: nil

  def tabs(assigns) do
    ~H"""
    <nav aria-label={@label || gettext("Views")} class="tabs tabs-border mb-4">
      <.link
        :for={item <- @items}
        patch={item.path}
        aria-current={item.path == @active && "page"}
        class={["tab gap-2", item.path == @active && "tab-active"]}
      >
        {item.label}
        <span :if={item[:badge] not in [nil, 0]} class="badge badge-md badge-ghost">
          {item[:badge]}
        </span>
      </.link>
    </nav>
    """
  end
end
