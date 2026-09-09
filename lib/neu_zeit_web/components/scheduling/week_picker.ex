defmodule NeuZeitWeb.Scheduling.WeekPicker do
  @moduledoc "Navigation through a teaching term."
  use NeuZeitWeb, :ui_component

  @doc """
  Selects a teaching week, with shortcuts for the first, last, busiest and holiday weeks.
  """
  attr :weeks_count, :integer, required: true
  attr :current, :integer, required: true
  attr :busiest, :integer, default: nil
  attr :holiday, :integer, default: nil
  attr :event, :string, default: "select_week"

  def week_picker(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2">
      <div class="join">
        <button
          type="button"
          class="btn btn-square join-item"
          disabled={@current <= 1}
          phx-click={@event}
          phx-value-week={@current - 1}
          aria-label={gettext("Previous week")}
        >
          <.icon name="hero-chevron-left" class="size-4" />
        </button>
        <span class="btn join-item pointer-events-none inline-grid font-semibold tabular-nums">
          <span aria-hidden="true" class="invisible col-start-1 row-start-1">
            {gettext("Week %{week} of %{total}", week: @weeks_count, total: @weeks_count)}
          </span>
          <span class="col-start-1 row-start-1">
            {gettext("Week %{week} of %{total}", week: @current, total: @weeks_count)}
          </span>
        </span>
        <button
          type="button"
          class="btn btn-square join-item"
          disabled={@current >= @weeks_count}
          phx-click={@event}
          phx-value-week={@current + 1}
          aria-label={gettext("Next week")}
        >
          <.icon name="hero-chevron-right" class="size-4" />
        </button>
      </div>

      <div class="flex flex-wrap gap-1">
        <button
          :for={{label, week} <- jumps(assigns)}
          type="button"
          class={["btn", @current == week && "btn-active"]}
          phx-click={@event}
          phx-value-week={week}
        >
          {label}
        </button>
      </div>
    </div>
    """
  end

  defp jumps(assigns) do
    [
      {gettext("First"), 1},
      {gettext("Last"), assigns.weeks_count},
      {gettext("Busiest"), assigns.busiest},
      {gettext("With non-teaching dates"), assigns.holiday}
    ]
    |> Enum.reject(fn {_label, week} -> is_nil(week) end)
    |> Enum.uniq_by(fn {label, week} -> {label, week} end)
  end
end
