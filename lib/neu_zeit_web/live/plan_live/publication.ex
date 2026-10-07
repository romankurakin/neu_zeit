defmodule NeuZeitWeb.PlanLive.Publication do
  @moduledoc false
  use NeuZeitWeb, :html

  attr :gate, :list, required: true
  attr :acknowledged, :map, required: true
  attr :advisory_count, :integer, required: true
  attr :form, Phoenix.HTML.Form, required: true, doc: "holds the name to publish under"

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
      <.form
        for={@form}
        id="publish-form"
        phx-change="publish_validate"
        phx-submit="publish_confirm"
      >
        <.input field={@form[:name]} label={gettext("Name")} required maxlength="100" />
      </.form>

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
          type="submit"
          form="publish-form"
          class="btn btn-primary"
          disabled={not publishable?(@gate, @acknowledged, @advisory_count)}
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

  # Each confirmation appears only when there is something to confirm.
  defp acknowledgements(advisory_count, gate) do
    unplaced = unplaced_count(gate)

    Enum.reject(
      [
        advisory_count > 0 &&
          {"advisories", gettext("I reviewed all warnings (%{count}).", count: advisory_count)},
        {"registers", gettext("I checked teacher names and group membership.")},
        unplaced > 0 &&
          {"partial",
           ngettext(
             "I want to publish with %{count} session still unplaced.",
             "I want to publish with %{count} sessions still unplaced.",
             unplaced,
             count: unplaced
           )}
      ],
      &(&1 == false)
    )
  end

  defp unplaced_count(gate) do
    case Enum.find(gate, &(&1.key == :unplaced)) do
      nil -> 0
      row -> row.count
    end
  end

  @doc """
  Whether every publication condition is met: no conflicts, and every shown
  confirmation ticked.
  """
  def publishable?(gate, acknowledged, advisory_count) do
    blocking = Enum.any?(gate, &(&1.key == :hard_checks and &1.status != :ok))

    confirmed =
      acknowledgements(advisory_count, gate)
      |> Enum.all?(fn {key, _label} -> Map.get(acknowledged, key) == true end)

    not blocking and confirmed
  end

  @doc """
  The name offered when publishing. A default draft name, such as "Draft 2",
  gives way to the term name.
  """
  def default_name(plan, term) do
    if default_draft_name?(plan.name), do: term.name, else: plan.name
  end

  defp default_draft_name?(name) do
    pattern =
      gettext("Draft %{n}", n: "\u0000")
      |> String.split("\u0000")
      |> Enum.map_join("\\d+", &Regex.escape/1)

    Regex.match?(~r/\A#{pattern}\z/u, name)
  end
end
