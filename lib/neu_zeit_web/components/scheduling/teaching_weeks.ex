defmodule NeuZeitWeb.Scheduling.TeachingWeeks do
  @moduledoc "Teaching-week labels and selection."
  use NeuZeitWeb, :ui_component

  @doc "Shows a recurrence label, with week numbers when the label does not identify them."
  attr :weeks, :list, required: true
  attr :total, :integer, required: true
  attr :class, :any, default: nil
  attr :compact, :boolean, default: false

  def teaching_weeks(assigns) do
    weeks = Enum.sort(Enum.uniq(assigns.weeks))

    assigns =
      assigns
      |> assign(:label, weeks_label(weeks, assigns.total))
      |> assign(
        :show_detail,
        weeks != [] and weeks != Enum.to_list(1..assigns.total//1) and
          length(summarize(weeks)) > 1
      )
      |> assign(
        :detail,
        gettext("Weeks %{list}", list: Enum.join(summarize(weeks), ", "))
      )

    ~H"""
    <span :if={@compact} class={["type-detail break-words", @class]} title={@detail}>{@label}</span>
    <div :if={!@compact} class={["type-detail", @class]}>
      <p>{@label}</p>
      <p :if={@show_detail} class="mt-1 type-detail text-base-content">{@detail}</p>
    </div>
    """
  end

  def weeks_label(weeks, total) do
    weeks = Enum.sort(Enum.uniq(weeks))
    all = Enum.to_list(1..total//1)

    cond do
      weeks == [] -> gettext("No teaching weeks")
      weeks == all -> gettext("Every week")
      weeks == Enum.filter(all, &(rem(&1, 2) == 1)) -> gettext("Odd weeks")
      weeks == Enum.filter(all, &(rem(&1, 2) == 0)) -> gettext("Even weeks")
      length(summarize(weeks)) == 1 -> gettext("Weeks %{list}", list: hd(summarize(weeks)))
      true -> ngettext("%{count} week", "%{count} weeks", length(weeks), count: length(weeks))
    end
  end

  # Combines consecutive weeks into ranges, for example "1-4, 7, 9-15".
  defp summarize([]), do: [gettext("none")]

  defp summarize(weeks) do
    weeks
    |> Enum.sort()
    |> Enum.chunk_while(
      nil,
      fn week, acc ->
        case acc do
          nil -> {:cont, {week, week}}
          {first, last} when week == last + 1 -> {:cont, {first, week}}
          range -> {:cont, range, {week, week}}
        end
      end,
      fn
        nil -> {:cont, nil}
        range -> {:cont, range, nil}
      end
    )
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn
      {same, same} -> "#{same}"
      {first, last} -> "#{first}-#{last}"
    end)
  end

  @doc """
  Selects an explicit set of teaching weeks. Includes all-week, odd-week and even-week presets.
  """
  attr :id, :string, required: true
  attr :weeks, :list, required: true
  attr :total, :integer, required: true
  attr :event, :string, default: "week_mask_changed"
  attr :name, :string, default: "week_mask"
  attr :parity_presets, :boolean, default: true

  def week_selector(assigns) do
    assigns = assign(assigns, :selected, MapSet.new(assigns.weeks))

    ~H"""
    <div id={@id} class="flex flex-col gap-2">
      <div class="flex flex-wrap gap-1">
        <button
          :for={week <- 1..@total//1}
          type="button"
          phx-click={@event}
          phx-value-week={week}
          aria-pressed={to_string(MapSet.member?(@selected, week))}
          class={[
            "btn btn-square tabular-nums",
            if(MapSet.member?(@selected, week), do: "btn-primary", else: "btn-ghost border-base-300")
          ]}
        >
          {week}
        </button>
      </div>

      <div class="flex flex-wrap items-center gap-2">
        <button type="button" class="btn" phx-click={@event} phx-value-preset="all">
          {gettext("Every week")}
        </button>
        <button
          :if={@parity_presets}
          type="button"
          class="btn"
          phx-click={@event}
          phx-value-preset="odd"
        >
          {gettext("Odd")}
        </button>
        <button
          :if={@parity_presets}
          type="button"
          class="btn"
          phx-click={@event}
          phx-value-preset="even"
        >
          {gettext("Even")}
        </button>
        <span class="ml-auto type-detail text-base-content">
          {ngettext("%{count} week", "%{count} weeks", MapSet.size(@selected),
            count: MapSet.size(@selected)
          )}
        </span>
      </div>

      <input :for={week <- Enum.sort(@selected)} type="hidden" name={"#{@name}[]"} value={week} />
    </div>
    """
  end
end
