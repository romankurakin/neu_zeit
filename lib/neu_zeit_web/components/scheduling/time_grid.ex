defmodule NeuZeitWeb.Scheduling.TimeGrid do
  @moduledoc "Time-slot selection for availability and time profiles."
  use NeuZeitWeb, :ui_component
  alias NeuZeit.Config
  import NeuZeitWeb.Scheduling.Labels

  @doc """
  Renders a day and time-slot grid for profiles, availability or read-only display.

  Click a cell to toggle it, or drag across cells to select or clear them.
  Day and time headers toggle a full row or column.

  Every control sends the cells it covers and the state those cells take.
  Pass that event to `apply_cells/2` to get the selection to store.
  """
  attr :id, :string, required: true
  attr :cells, :list, required: true, doc: "selected cells as %{day: _, slot: _} or {day, slot}"
  attr :event, :string, default: "grid_changed"
  attr :readonly, :boolean, default: false
  attr :legend, :string, default: nil
  attr :grid, :map, default: nil

  def time_grid(assigns) do
    grid = assigns.grid || Config.grid!()
    selected = MapSet.new(assigns.cells, &normalize_cell/1)

    assigns =
      assigns
      |> assign(:days, Enum.with_index(Enum.map(grid.days, &day_label/1), 1))
      |> assign(:slots, Enum.with_index(grid.slots, 1))
      |> assign(:selected, selected)

    ~H"""
    <div class="overflow-x-auto">
      <div
        id={@id}
        phx-hook=".GridPaint"
        data-event={@event}
        data-readonly={to_string(@readonly)}
        class="inline-grid select-none gap-1"
        style={"grid-template-columns: 5.5rem repeat(#{length(@days)}, minmax(3.5rem, 1fr));"}
      >
        <span></span>
        <button
          :for={{day, day_index} <- @days}
          type="button"
          disabled={@readonly}
          phx-click={toggle(@event, @selected, day_cells(@slots, day_index))}
          class="btn btn-ghost font-semibold"
          title={gettext("Toggle all of %{day}", day: day)}
        >
          {day}
        </button>

        <%= for {slot, slot_index} <- @slots do %>
          <button
            type="button"
            disabled={@readonly}
            phx-click={toggle(@event, @selected, slot_cells(@days, slot_index))}
            class="btn btn-ghost justify-end tabular-nums type-detail"
            title={gettext("Toggle time slot %{slot} on every day", slot: slot_index)}
          >
            {slot.start}
          </button>
          <button
            :for={{_day, day_index} <- @days}
            type="button"
            data-cell="true"
            data-day={day_index}
            data-slot={slot_index}
            data-selected={to_string(MapSet.member?(@selected, {day_index, slot_index}))}
            disabled={@readonly}
            phx-click={toggle(@event, @selected, [{day_index, slot_index}])}
            aria-pressed={to_string(MapSet.member?(@selected, {day_index, slot_index}))}
            aria-label={gettext("Day %{day}, time slot %{slot}", day: day_index, slot: slot_index)}
            class={
              [
                "h-8 rounded-field border motion-safe:transition-colors",
                "data-[selected=true]:border-primary data-[selected=true]:bg-primary/70",
                "data-[selected=false]:border-base-300 data-[selected=false]:bg-base-200",
                # The pointer preview outranks the stored state until the server answers,
                # and follows the pointer, so it must not fade in behind it.
                "data-[paint=true]:border-primary! data-[paint=true]:bg-primary/70!",
                "data-[paint=false]:border-base-300! data-[paint=false]:bg-base-200!",
                "data-paint:transition-none!",
                !@readonly && "hover:border-primary/60 cursor-pointer"
              ]
            }
          ></button>
        <% end %>
      </div>

      <p :if={@legend} class="mt-2 type-detail text-base-content">{@legend}</p>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".GridPaint">
      import { closestHtmlElement, defineHook, htmlElements } from "@/js/hook-dom.js";

      /** @typedef {Readonly<{day: number, slot: number}>} Cell */

      export default defineHook({
        clear() {
          for (const cell of htmlElements(this.el, "[data-paint]")) {
            delete cell.dataset.paint;
          }
          this.painted = [];
        },
        destroyed() {
          globalThis.removeEventListener("pointerup", this.onPointerUp);
        },
        disconnected() {
          // Only the server holds the stored selection, so drop an unanswered preview.
          this.dragging = false;
          this.clear();
        },
        dragging: false,
        mode: "false",
        mounted() {
          this.onPointerUp = this.onPointerUp.bind(this);
          this.painted = [];
          this.el.addEventListener("pointerdown", (event) => {
            this.startPaint(event);
          });
          this.el.addEventListener("pointerover", (event) => {
            if (this.dragging) {
              this.paint(closestHtmlElement(event.target, "[data-cell]"));
            }
          });
          // The press already sent the cell, so its click must not reach phx-click.
          this.el.addEventListener(
            "click",
            (event) => {
              if (this.swallow) {
                this.swallow = false;
                event.preventDefault();
                event.stopPropagation();
              }
            },
            true,
          );
          globalThis.addEventListener("pointerup", this.onPointerUp);
        },
        /** @param {PointerEvent} event */
        onPointerUp(event) {
          if (this.dragging) {
            this.dragging = false;
            // A press that ends on a cell also fires a click on it.
            this.swallow = closestHtmlElement(event.target, "[data-cell]") instanceof HTMLElement;
            this.pushPaint();
          }
        },
        /** @param {HTMLElement | null} cell */
        paint(cell) {
          if (cell instanceof HTMLElement && cell.dataset.paint !== this.mode) {
            cell.dataset.paint = this.mode;
            this.painted.push({ day: Number(cell.dataset.day), slot: Number(cell.dataset.slot) });
          }
        },
        /** @type {Cell[]} */
        painted: [],
        pushPaint() {
          if (typeof this.el.dataset.event !== "string") {
            throw new TypeError("Missing grid event");
          }
          this.pushEvent(
            this.el.dataset.event,
            { cells: this.painted, selected: this.mode === "true" },
            () => {
              this.clear();
            },
          );
        },
        /** @param {PointerEvent} event */
        startPaint(event) {
          const cell = closestHtmlElement(event.target, "[data-cell]");
          if (this.el.dataset.readonly !== "true" && cell instanceof HTMLElement) {
            // Painting owns the pointer. The browser must not select text or drag.
            event.preventDefault();
            // A gesture that starts before the last answer arrives drops the old preview.
            this.clear();
            this.dragging = true;
            this.mode = String(cell.dataset.selected !== "true");
            this.paint(cell);
          }
        },
        swallow: false,
      });
    </script>
    """
  end

  @doc """
  Applies a grid event to the stored selection.

  Returns the cells to store, sorted, with the string keys changesets expect.
  """
  def apply_cells(stored, %{"cells" => cells, "selected" => selected?}) do
    covered = MapSet.new(cells, &normalize_cell/1)
    stored = MapSet.new(stored, &normalize_cell/1)

    next =
      if selected?,
        do: MapSet.union(stored, covered),
        else: MapSet.difference(stored, covered)

    next |> Enum.sort() |> Enum.map(fn {day, slot} -> %{"day" => day, "slot" => slot} end)
  end

  defp toggle(event, selected, cells) do
    JS.push(event,
      value: %{
        cells: Enum.map(cells, fn {day, slot} -> %{day: day, slot: slot} end),
        selected: not Enum.all?(cells, &MapSet.member?(selected, &1))
      }
    )
  end

  defp day_cells(slots, day), do: for({_slot, index} <- slots, do: {day, index})
  defp slot_cells(days, slot), do: for({_day, index} <- days, do: {index, slot})

  defp normalize_cell(%{day: day, slot: slot}), do: {day, slot}
  defp normalize_cell(%{"day" => day, "slot" => slot}), do: {day, slot}
  defp normalize_cell({day, slot}), do: {day, slot}
end
