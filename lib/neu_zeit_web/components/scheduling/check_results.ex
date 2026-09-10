defmodule NeuZeitWeb.Scheduling.CheckResults do
  @moduledoc "Readiness and publication checks."
  use NeuZeitWeb, :ui_component
  import NeuZeitWeb.UI.Table
  import NeuZeitWeb.UI.Status

  @doc """
  Renders checklist results with details.

  Pass `navigate` only on a row that asks for work, and name its destination in
  `action_label`.
  """
  attr :id, :string, required: true

  slot :item, required: true do
    attr :status, :any, required: true
    attr :label, :string, required: true
    attr :detail, :string
    attr :navigate, :string
    attr :action_label, :string
  end

  def check_results(assigns) do
    ~H"""
    <.table id={@id} rows={@item}>
      <:col :let={item} label={gettext("Status")} class="w-0 whitespace-nowrap">
        <.status_indicator status={item.status} />
      </:col>
      <:col :let={item} label={gettext("Checks")} class="w-full min-w-64 whitespace-normal">
        <p class="font-semibold">{item.label}</p>
        <p :if={item[:detail]}>{item[:detail]}</p>
      </:col>
      <:col :let={item} label={gettext("Value")} numeric class="w-0 whitespace-nowrap">
        {render_slot(item)}
      </:col>
      <:action :let={item} :if={Enum.any?(@item, & &1[:navigate])}>
        <.link :if={item[:navigate]} navigate={item[:navigate]} class="btn btn-ghost">
          {item[:action_label]}
        </.link>
      </:action>
    </.table>
    """
  end
end
