defmodule NeuZeitWeb.UI.DateField do
  @moduledoc "Date entry with a calendar for the dates a field allows."
  use NeuZeitWeb, :ui_component

  @doc """
  Renders a date field with a calendar beside it.

  The field stays a date input, so typing a date keeps working. The calendar
  replaces the one the browser puts inside the input, which cannot grey out the
  dates the field refuses. Month names follow the language of the interface.

  Safari before 17 has no popover. There the calendar is removed and the input
  stands on its own.
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :min, :any, default: nil, doc: "earliest date, as %Date{} or nil"
  attr :max, :any, default: nil, doc: "latest date, as %Date{} or nil"
  attr :weekday, :integer, default: nil, doc: "the only weekday to allow, 1 is Monday"
  attr :disallowed, :list, default: [], doc: "dates the field refuses, as %Date{}"

  def date_field(assigns) do
    errors = if Phoenix.Component.used_input?(assigns.field), do: assigns.field.errors, else: []

    assigns =
      assigns
      |> assign(:errors, Enum.map(errors, &NeuZeitWeb.CoreComponents.translate_error/1))
      |> assign(:popover_id, "#{assigns.field.id}-calendar")
      |> assign(:locale, Gettext.get_locale(NeuZeitWeb.Gettext))

    ~H"""
    <div
      class="date-field fieldset type-detail"
      id={"#{@field.id}-picker"}
      phx-hook=".DateField"
      data-weekday={@weekday}
      data-disallowed={Enum.map_join(@disallowed, ",", &Date.to_iso8601/1)}
    >
      <label for={@field.id}>
        <span class="label mb-1">{@label}</span>
        <div class="join w-full">
          <input
            type="date"
            id={@field.id}
            name={@field.name}
            value={Phoenix.HTML.Form.normalize_value("date", @field.value)}
            min={@min && Date.to_iso8601(@min)}
            max={@max && Date.to_iso8601(@max)}
            class={["input join-item w-full", @errors != [] && "input-error"]}
          />
          <button
            type="button"
            popovertarget={@popover_id}
            style={"anchor-name:--#{@field.id}"}
            class="btn join-item btn-square"
            aria-label={gettext("Open the calendar")}
          >
            <.icon name="hero-calendar-days" class="size-4" />
          </button>
        </div>
      </label>

      <div
        popover
        id={@popover_id}
        style={"position-anchor:--#{@field.id}"}
        class="dropdown rounded-box border border-base-300 bg-base-100 type-detail shadow-lg"
      >
        <calendar-date
          class="cally"
          locale={@locale}
          first-day-of-week="1"
          min={@min && Date.to_iso8601(@min)}
          max={@max && Date.to_iso8601(@max)}
        >
          <span
            slot="previous"
            aria-label={gettext("Previous month")}
            class="hero-chevron-left size-4"
          ></span>
          <span slot="next" aria-label={gettext("Next month")} class="hero-chevron-right size-4"></span>
          <calendar-month></calendar-month>
        </calendar-date>
      </div>

      <.error :for={message <- @errors}>{message}</.error>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".DateField">
      import "cally";
      import { defineHook } from "@/js/hook-dom.js";

      // Canadian English writes a local date as YYYY-MM-DD, the form the field carries.
      const isoDate = "en-CA";

      export default defineHook({
        /** The server owns the constraints, so read them again after every patch. */
        apply() {
          const calendar = this.calendar();
          const { disallowed, weekday } = this.el.dataset;
          const refused = new Set((disallowed ?? "").split(","));
          calendar.isDateDisallowed = (date) => {
            if (typeof weekday === "string" && String(date.getDay()) !== weekday) {
              return true;
            }
            return refused.has(date.toLocaleDateString(isoDate));
          };
          calendar.value = this.input().value;
        },
        calendar() {
          const element = this.el.querySelector("calendar-date");
          if (!element) {
            throw new TypeError("Missing calendar");
          }
          return element;
        },
        destroyed() {
          const calendar = this.el.querySelector("calendar-date");
          if (calendar) {
            calendar.removeEventListener("change", this.onPick);
          }
          this.input().removeEventListener("change", this.onType);
        },
        input() {
          const element = this.el.querySelector("input[type=date]");
          if (!(element instanceof HTMLInputElement)) {
            throw new TypeError("Missing date input");
          }
          return element;
        },
        mounted() {
          // Safari before 17 shows a popover inline instead of hiding it.
          // There the date input stands on its own, so the calendar goes.
          if (!("showPopover" in HTMLElement.prototype)) {
            for (const part of this.el.querySelectorAll("[popover], [popovertarget]")) {
              part.remove();
            }
            return;
          }
          this.onPick = this.onPick.bind(this);
          this.onType = this.onType.bind(this);
          this.calendar().addEventListener("change", this.onPick);
          this.input().addEventListener("change", this.onType);
          this.apply();
        },
        onPick() {
          const input = this.input();
          input.value = this.calendar().value;
          // The form listens for input events, and the calendar has done its work.
          input.dispatchEvent(new Event("input", { bubbles: true }));
          const popover = this.el.querySelector("[popover]");
          if (popover instanceof HTMLElement) {
            popover.hidePopover();
          }
        },
        onType() {
          this.calendar().value = this.input().value;
        },
        updated() {
          this.apply();
        },
      });
    </script>
    """
  end
end
