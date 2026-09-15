defmodule NeuZeitWeb.UI.TimeField do
  @moduledoc "Clock time entry with the timepicker-ui compact wheel."
  use NeuZeitWeb, :ui_component

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :any, default: nil
  attr :label, :string, default: nil
  attr :errors, :list, default: []
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(disabled form required readonly)

  def time_field(assigns) do
    id = assigns.id || "time-#{String.replace(to_string(assigns.name), ~r/[^a-zA-Z0-9_-]/, "-")}"
    assigns = assign(assigns, :id, id)

    ~H"""
    <div
      id={"#{@id}-time-picker"}
      class="fieldset type-detail min-w-0"
      phx-hook=".TimeField"
      data-label-choose={gettext("Choose time")}
      data-label-hours={gettext("Hours")}
      data-label-minutes={gettext("Minutes")}
      data-label-done={gettext("Done")}
      data-label-cancel={gettext("Cancel")}
      data-label-invalid={gettext("Enter time as HH:MM.")}
    >
      <label :if={@label} for={@id} class="label mb-1">{@label}</label>
      <div class="tp-ui join w-full">
        <input
          type="text"
          id={@id}
          name={@name}
          value={Phoenix.HTML.Form.normalize_value("time", @value)}
          inputmode="numeric"
          placeholder="00:00"
          pattern="([01][0-9]|2[0-3]):[0-5][0-9]"
          maxlength="5"
          autocomplete="off"
          class={[
            @class || "input join-item w-full min-w-0 tabular-nums",
            @errors != [] && "input-error"
          ]}
          {@rest}
        />
        <button
          type="button"
          data-open="time-picker"
          class="btn btn-square join-item"
          disabled={@rest[:disabled] || @rest[:readonly]}
          aria-label={gettext("Choose time")}
        >
          <.icon name="hero-clock" class="size-4" />
        </button>
      </div>
      <.error :for={message <- @errors}>{message}</.error>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".TimeField">
      import TimeField from "@/js/time-field";

      export default TimeField;
    </script>
    """
  end
end
