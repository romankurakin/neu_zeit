defmodule NeuZeitWeb.PlanLive.Publication do
  @moduledoc false
  use NeuZeitWeb, :html

  attr :gate, :list, required: true
  attr :acknowledged, :map, required: true
  attr :advisory_count, :integer, required: true

  def confirmation(assigns) do
    ~H"""
      <.dialog id="publish-gate" title={gettext("Publish this plan?")} on_cancel="publish_cancel" class="max-w-2xl"
        description={gettext("This plan will replace the published timetable. The previous plan will be archived. One-off changes will be kept.")}>
            <.check_results id="publication-checks">
              <:item :for={row <- gate_rows(@gate)} status={row.status} label={row.label}>
                {row.detail}
              </:item>
            </.check_results>

          <div class="flex flex-col gap-2">
            <label :for={{key, label} <- acknowledgements(@advisory_count)} class="flex cursor-pointer items-start gap-2 type-detail">
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

  defp acknowledgements(count) do
    [
      {"advisories", gettext("I reviewed all warnings (%{count}).", count: count)},
      {"registers", gettext("I checked teacher names and group membership.")}
    ]
  end

  defp publishable?(gate, acknowledged) do
    blocking =
      Enum.any?(gate, fn row ->
        row.key in [:unplaced, :hard_checks] and row.status != :ok
      end)

    confirmed = Enum.all?(["advisories", "registers"], &Map.get(acknowledged, &1))

    not blocking and confirmed
  end
end
