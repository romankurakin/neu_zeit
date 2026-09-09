defmodule NeuZeitWeb.Scheduling.TimeGrid do
  @moduledoc "Time-slot selection for availability and time profiles."
  use NeuZeitWeb, :ui_component
  alias NeuZeit.Config
  import NeuZeitWeb.Scheduling.Labels

  @doc """
  Renders a day and time-slot grid for profiles, availability or read-only display.

  Click a cell to toggle it, or drag across cells to select or clear them.
  Day and time headers toggle a full row or column.
  Each event sends the complete selection for the server to validate and replace.
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
          data-header="day"
          data-day={day_index}
          disabled={@readonly}
          class="btn btn-ghost font-semibold"
          title={gettext("Toggle all of %{day}", day: day)}
        >
          {day}
        </button>

        <%= for {slot, slot_index} <- @slots do %>
          <button
            type="button"
            data-header="slot"
            data-slot={slot_index}
            disabled={@readonly}
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
            aria-pressed={to_string(MapSet.member?(@selected, {day_index, slot_index}))}
            aria-label={gettext("Day %{day}, time slot %{slot}", day: day_index, slot: slot_index)}
            class={[
              "h-8 rounded-field border transition-colors",
              "data-[selected=true]:border-primary data-[selected=true]:bg-primary/70",
              "data-[selected=false]:border-base-300 data-[selected=false]:bg-base-200",
              !@readonly && "hover:border-primary/60 cursor-pointer"
            ]}
          >
          </button>
        <% end %>
      </div>

      <p :if={@legend} class="mt-2 type-detail text-base-content">{@legend}</p>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".GridPaint">
      import {closestHtmlElement, defineHook, htmlElements} from "@/js/hook-dom.js"

      const keyboardClick = 0

      /** @typedef {Readonly<{day: number, slot: number}>} Cell */

      export default defineHook({
        /** @type {readonly Cell[]} */
        confirmed: [],
        destroyed() {
          globalThis.removeEventListener("pointerup", this.onPointerUp)
        },
        disconnected() {
          this.painting = false
          this.pending = true
          this.restore(this.confirmed)
        },
        mode: "false",
        mounted() {
          this.onPointerUp = this.onPointerUp.bind(this)
          this.confirmed = this.readCells()
          this.el.addEventListener("pointerdown", (event) => {
            this.startPaint(event)
          })
          this.el.addEventListener("pointerover", (event) => {
            if (this.painting) {
              this.paint(closestHtmlElement(event.target, "[data-cell]"))
            }
          })
          this.el.addEventListener("click", (event) => {
            this.toggleCells(event)
          })
          globalThis.addEventListener("pointerup", this.onPointerUp)
        },
        onPointerUp() {
          if (this.painting) {
            this.painting = false
            this.pushCells()
          }
        },
        /** @param {HTMLElement | null} cell */
        paint(cell) {
          if (cell instanceof HTMLElement && cell.dataset.selected !== this.mode) {
            cell.dataset.selected = this.mode
            cell.setAttribute("aria-pressed", this.mode)
          }
        },
        painting: false,
        pending: false,
        pushCells() {
          if (typeof this.el.dataset.event !== "string") {
            throw new TypeError("Missing grid event")
          }
          this.pending = true
          this.el.setAttribute("aria-busy", "true")
          this.pushEvent(
            this.el.dataset.event,
            {cells: this.readCells(), id: this.el.id},
            /** @param {Readonly<{cells: readonly Cell[]}>} reply */
            (reply) => {
              this.receiveCells(reply.cells)
            },
          )
        },
        readCells() {
          return htmlElements(this.el, '[data-cell][data-selected="true"]').map((cell) => ({
            day: Number(cell.dataset.day),
            slot: Number(cell.dataset.slot),
          }))
        },
        /** @param {readonly Cell[]} cells */
        receiveCells(cells) {
          this.confirmed = cells
          this.restore(cells)
          this.pending = false
          this.el.setAttribute("aria-busy", "false")
        },
        reconnected() {
          this.pending = false
          this.confirmed = this.readCells()
          this.el.setAttribute("aria-busy", "false")
        },
        /** @param {readonly Cell[]} cells */
        restore(cells) {
          const selected = new Set(cells.map((cell) => `${cell.day}:${cell.slot}`))
          for (const cell of htmlElements(this.el, "[data-cell]")) {
            const value = String(selected.has(`${cell.dataset.day}:${cell.dataset.slot}`))
            cell.dataset.selected = value
            cell.setAttribute("aria-pressed", value)
          }
        },
        /** @param {PointerEvent} event */
        startPaint(event) {
          if (this.el.dataset.readonly === "true" || this.pending) {
            return
          }
          const cell = closestHtmlElement(event.target, "[data-cell]")
          if (cell instanceof HTMLElement) {
            event.preventDefault()
            this.painting = true
            this.mode = String(cell.dataset.selected !== "true")
            this.paint(cell)
          }
        },
        /** @param {MouseEvent} event */
        toggleCells(event) {
          if (this.el.dataset.readonly === "true" || this.pending) {
            return
          }
          const cell = closestHtmlElement(event.target, "[data-cell]")
          const header = closestHtmlElement(event.target, "[data-header]")
          if (cell instanceof HTMLElement && event.detail === keyboardClick) {
            this.mode = String(cell.dataset.selected !== "true")
            this.paint(cell)
            this.pushCells()
          } else if (header instanceof HTMLElement) {
            this.toggleHeader(header)
          }
        },
        /** @param {HTMLElement} header */
        toggleHeader(header) {
          let attribute = "slot"
          if (header.dataset.header === "day") {
            attribute = "day"
          }
          const cells = htmlElements(
            this.el,
            `[data-cell][data-${attribute}="${header.dataset[attribute]}"]`,
          )
          const next = String(!cells.every((cell) => cell.dataset.selected === "true"))
          for (const cell of cells) {
            cell.dataset.selected = next
            cell.setAttribute("aria-pressed", next)
          }
          this.pushCells()
        },
        updated() {
          if (!this.pending) {
            this.confirmed = this.readCells()
          }
        },
      })
    </script>
    """
  end

  defp normalize_cell(%{day: day, slot: slot}), do: {day, slot}
  defp normalize_cell(%{"day" => day, "slot" => slot}), do: {day, slot}
  defp normalize_cell({day, slot}), do: {day, slot}
end
