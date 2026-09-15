defmodule NeuZeitWeb.UI.Status do
  @moduledoc "Status labels and semantic colors."
  use NeuZeitWeb, :ui_component

  @statuses %{
    # plan lifecycle
    draft: "hero-pencil-square",
    active: "hero-check-circle",
    archived: "hero-archive-box",
    # diagnostics
    blocked: "hero-x-circle",
    error: "hero-exclamation-circle",
    warning: "hero-exclamation-triangle",
    advisory: "hero-question-mark-circle",
    ok: "hero-check-circle",
    info: "hero-information-circle",
    unknown: "hero-minus-circle",
    # teaching-hour coverage
    under: "hero-arrow-trending-down",
    over: "hero-arrow-trending-up"
  }

  @doc """
  Renders an icon and status text without a badge. Equal icon widths align labels.
  Only the icon uses semantic theme colors; the text keeps its inherited color.
  """
  attr :status, :any, required: true
  attr :label, :string, default: nil, doc: "overrides the default label"
  attr :rest, :global

  def status_indicator(assigns) do
    assigns =
      assigns
      |> assign(:icon, lookup(assigns.status))
      |> assign(:icon_tone, value_tone(assigns.status))
      |> assign(:text, assigns.label || status_label(assigns.status))

    ~H"""
    <span class="inline-flex items-center gap-2" {@rest}>
      <.icon name={@icon} class={["size-4 shrink-0", @icon_tone]} />
      <span>{@text}</span>
    </span>
    """
  end

  defp lookup(status) when is_binary(status) do
    lookup(String.to_existing_atom(status))
  rescue
    ArgumentError -> Map.fetch!(@statuses, :unknown)
  end

  defp lookup(status) when is_atom(status),
    do: Map.get(@statuses, status, Map.fetch!(@statuses, :unknown))

  @doc "Returns the translated status text for tables and other plain-text output."
  def status_label(status) when is_binary(status) do
    status_label(String.to_existing_atom(status))
  rescue
    ArgumentError -> gettext("Not checked")
  end

  def status_label(:draft), do: gettext("Draft")
  def status_label(:active), do: gettext("Active")
  def status_label(:archived), do: gettext("Archived")
  def status_label(:blocked), do: gettext("Blocked")
  def status_label(:error), do: gettext("Conflict")
  def status_label(:warning), do: gettext("Review")
  def status_label(:advisory), do: gettext("Warning")
  def status_label(:ok), do: gettext("OK")
  def status_label(:info), do: gettext("Info")
  def status_label(:under), do: gettext("Under")
  def status_label(:over), do: gettext("Over")
  def status_label(_status), do: gettext("Not checked")

  def value_tone(nil), do: nil
  def value_tone(status) when status in [:error, :blocked, "error", "blocked"], do: "text-error"

  def value_tone(status)
      when status in [:warning, :advisory, :under, :over, "warning", "advisory", "under", "over"],
      do: "text-warning"

  def value_tone(status) when status in [:ok, :active, "ok", "active"], do: "text-success"
  def value_tone(_status), do: nil
end
