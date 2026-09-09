defmodule NeuZeitWeb.UI.Table do
  @moduledoc "A semantic table with columns, actions and an empty state."
  use NeuZeitWeb, :ui_component

  @doc """
  A dense table with a pinned header and a built-in empty state.

  Text and tags align left. Numeric columns and their headers align right with
  tabular digits. Actions keep a separate right-aligned cell, even when empty.

  Works with plain lists and with LiveView streams; pass `row_id`/`row_item` the
  same way `Phoenix` core components do.
  """
  attr :id, :string, required: true
  attr :rows, :any, required: true
  attr :row_id, :any, default: nil
  attr :row_item, :any, default: &Function.identity/1
  attr :row_click, :any, default: nil
  attr :empty_message, :string, default: nil
  attr :stream, :boolean, default: false

  slot :col, required: true do
    attr :label, :string
    attr :class, :any
    attr :numeric, :boolean
  end

  slot :action

  def table(assigns) do
    ~H"""
    <% assigns = assign_new(assigns, :empty_text, fn -> assigns.empty_message || gettext("Nothing here yet.") end) %>
    <div class="card card-border overflow-x-auto border-base-300 bg-base-100">
      <table class="table table-pin-rows">
        <thead>
          <tr>
            <th :for={col <- @col} scope="col" class={[col[:class], if(col[:numeric], do: "text-right tabular-nums", else: "text-left")]}>{col[:label]}</th>
            <th :if={@action != []} scope="col" class="text-right">{gettext("Actions")}</th>
          </tr>
        </thead>
        <tbody id={@id} phx-update={@stream && "stream"}>
          <tr id={"#{@id}-empty"} class="hidden only:table-row">
            <td colspan={length(@col) + if(@action != [], do: 1, else: 0)}>
              <p class="py-6 text-center type-detail text-base-content">{@empty_text}</p>
            </td>
          </tr>
          <tr
            :for={row <- @rows}
            id={@row_id && @row_id.(row)}
            class={["hover:bg-base-200/60", @row_click && "cursor-pointer"]}
            phx-click={@row_click && @row_click.(row)}
          >
            <td :for={col <- @col} class={[col[:class], if(col[:numeric], do: "text-right tabular-nums", else: "text-left")]}>
              {render_slot(col, @row_item.(row))}
            </td>
            <td :if={@action != []} class="w-0 whitespace-nowrap text-right">
              {render_slot(@action, @row_item.(row))}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
