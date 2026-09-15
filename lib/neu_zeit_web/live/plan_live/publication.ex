defmodule NeuZeitWeb.PlanLive.Publication do
  @moduledoc false
  use NeuZeitWeb, :html

  attr :gate, :list, required: true
  attr :acknowledged, :map, required: true
  attr :advisory_count, :integer, required: true

  def confirmation(assigns) do
    ~H"""
    <.dialog
      id="publish-gate"
      title={gettext("Publish this plan?")}
      on_cancel="publish_cancel"
      class="max-w-2xl"
      description={
        gettext(
          "This plan will replace the published timetable. The previous plan will be archived. One-off changes will be kept."
        )
      }
    >
      <.check_results id="publication-checks">
        <:item :for={row <- gate_rows(@gate)} status={row.status} label={row.label}>
          {row.detail}
        </:item>
      </.check_results>

      <p :if={unplaced_count(@gate) > 0} class="mb-4 text-warning">
        {gettext(
          "Only placed sessions will appear in the published timetable. You can add the remaining sessions in a draft copy and publish it later."
        )}
      </p>
      <div class="flex flex-col gap-2">
        <label
          :for={{key, label} <- acknowledgements(@advisory_count, @gate)}
          class="flex cursor-pointer items-start gap-2 type-detail"
        >
          <input
            type="checkbox"
            class="checkbox checkbox-sm mt-0.5"
            checked={Map.get(@acknowledged, key, false)}
            phx-click="acknowledge"
            phx-value-key={key}
          />
          <span>{label}</span>
        </label>
      </div>

      <:actions>
        <button type="button" class="btn btn-soft" phx-click="publish_cancel" autofocus>
          {gettext("Cancel")}
        </button>
        <button
          type="button"
          class="btn btn-primary"
          phx-click="publish_confirm"
          disabled={not publishable?(@gate, @acknowledged)}
        >
          {gettext("Publish plan")}
        </button>
      </:actions>
    </.dialog>
    """
  end

  # Placement and conflict checks are automatic. The remaining confirmations require review.
  defp gate_rows(report) do
    for key <- [:unplaced, :hard_checks, :advisories],
        row = Enum.find(report, &(&1.key == key)),
        do: %{status: row.status, label: gate_label(key), detail: gate_detail(key, row.count)}
  end

  defp gate_label(:unplaced), do: gettext("Unplaced")
  defp gate_label(:hard_checks), do: gettext("Conflicts")
  defp gate_label(:advisories), do: gettext("Warnings to review")

  defp gate_detail(_key, 0), do: "0"
  defp gate_detail(_key, count), do: to_string(count)

  defp acknowledgements(count, gate) do
    base = [
      {"advisories", gettext("I reviewed all warnings (%{count}).", count: count)},
      {"registers", gettext("I checked teacher names and group membership.")}
    ]

    count = unplaced_count(gate)

    if count > 0 do
      base ++
        [
          {"partial",
           ngettext(
             "I want to publish with %{count} session still unplaced.",
             "I want to publish with %{count} sessions still unplaced.",
             count,
             count: count
           )}
        ]
    else
      base
    end
  end

  defp unplaced_count(gate) do
    case Enum.find(gate, &(&1.key == :unplaced)) do
      nil -> 0
      row -> row.count
    end
  end

  def publishable?(gate, acknowledged) do
    blocking =
      Enum.any?(gate, fn row ->
        row.key == :hard_checks and row.status != :ok
      end)

    confirmed = Enum.all?(["advisories", "registers"], &Map.get(acknowledged, &1))

    partial_confirmed = unplaced_count(gate) == 0 || Map.get(acknowledged, "partial") == true
    not blocking and confirmed and partial_confirmed
  end
end
