defmodule NeuZeitWeb.Scheduling.Timetable do
  @moduledoc "A timetable with readable lanes and drag placement."
  use NeuZeitWeb, :ui_component
  alias NeuZeit.Config
  import NeuZeitWeb.Scheduling.Labels
  import NeuZeitWeb.Scheduling.SessionCard

  attr :id, :string, required: true
  attr :placements, :list, required: true
  attr :week, :integer, required: true
  attr :weeks_count, :integer, required: true
  attr :grid, :map, default: nil
  attr :legal, :map, default: %{}
  attr :selected_session_id, :string, default: nil
  attr :selected_placement_id, :string, default: nil
  attr :highlighting, :boolean, default: false
  attr :on_select, :any, default: nil
  attr :on_place, :any, default: nil
  attr :readonly, :boolean, default: false

  def timetable(assigns) do
    grid = assigns.grid || Config.grid!()
    placed = Enum.filter(assigns.placements, &(assigns.week in &1.week_mask))

    positioned = position(placed)

    lanes =
      Map.new(Enum.group_by(positioned, fn {p, _, _} -> p.day end), fn {day, rows} ->
        {day, rows |> Enum.map(&elem(&1, 2)) |> Enum.max()}
      end)

    columns =
      Enum.map_join(1..length(grid.days), " ", fn day ->
        "minmax(#{Map.get(lanes, day, 1) * 14}rem, 1fr)"
      end)

    assigns =
      assigns
      |> assign(:columns, columns)
      |> assign(
        :min_width,
        5 + Enum.sum(for day <- 1..length(grid.days), do: Map.get(lanes, day, 1) * 14)
      )
      |> assign(:grid, grid)
      |> assign(:days, Enum.with_index(Enum.map(grid.days, &day_label/1), 1))
      |> assign(:slots, Enum.with_index(grid.slots, 1))
      |> assign(:positioned, positioned)

    ~H"""
    <div
      class="min-w-0 max-w-full min-h-80 max-h-[calc(100dvh-22rem)] overflow-auto pb-2"
      tabindex="0"
      role="region"
      aria-label={gettext("Timetable. Scroll horizontally to see all days.")}
    >
      <div
        id={@id}
        phx-hook=".BoardDrag"
        data-readonly={to_string(@readonly)}
        class="grid gap-1 min-w-full"
        style={"min-width: calc(#{@min_width}rem + #{length(@days)} * var(--spacing)); grid-template-columns: 5rem #{@columns}; grid-template-rows: auto repeat(#{length(@slots)}, minmax(10rem, auto));"}
      >
        <span class="sticky left-0 top-0 z-20 bg-base-200"></span>
        <div
          :for={{day, index} <- @days}
          class="sticky top-0 z-10 bg-base-200 py-1 text-center type-detail font-semibold"
          style={"grid-column: #{index + 1}; grid-row: 1;"}
        >
          {day}
        </div>
        <%= for {slot, slot_index} <- @slots do %>
          <div
            class="sticky left-0 z-10 bg-base-200 text-right type-detail tabular-nums pt-2 pr-2"
            style={"grid-column: 1; grid-row: #{slot_index + 1};"}
          >
            {slot.start}<br />{slot.end}
          </div>
          <div
            :for={{day, day_index} <- @days}
            id={"#{@id}-cell-#{day_index}-#{slot_index}"}
            data-dropzone="cell"
            data-day={day_index}
            data-slot={slot_index}
            style={"grid-column: #{day_index + 1}; grid-row: #{slot_index + 1};"}
            class={[
              "rounded-box border border-base-300 bg-base-200 min-h-40",
              Map.has_key?(@legal, {day_index, slot_index}) && !@readonly &&
                "border-success bg-success/10"
            ]}
          >
            <button
              :if={@highlighting && !@readonly}
              type="button"
              class="btn btn-ghost font-normal w-full h-full items-start pt-1 whitespace-normal"
              phx-click={@on_place}
              phx-value-day={day_index}
              phx-value-slot={slot_index}
              aria-label={gettext("Inspect position: %{day}, %{time}", day: day, time: slot.start)}
            >
              {if Map.has_key?(@legal, {day_index, slot_index}),
                do: gettext("Available"),
                else: gettext("Check constraints")}
            </button>
          </div>
        <% end %>
        <.session_card
          :for={{placement, lane, count} <- @positioned}
          id={"#{@id}-placement-#{placement.id}"}
          session={placement.session}
          placement={placement}
          weeks_count={@weeks_count}
          grid={@grid}
          selected={@selected_placement_id == placement.id}
          on_select={@on_select}
          style={"grid-column: #{placement.day + 1}; grid-row: #{placement.slot + 1} / span #{placement.duration_slots}; z-index: 1; width: calc(100% / #{count} - var(--spacing) / 2); margin-left: calc(100% * #{lane} / #{count});"}
        />
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".BoardDrag">
      import {
        acknowledgePatch,
        defineHook,
        dragAnimation,
        htmlElements,
        restoreDraggedItem,
      } from "@/js/hook-dom";
      import Sortable from "sortablejs";

      export default defineHook({
        /** @param {HTMLElement} zone */
        createSorter(zone) {
          return Sortable.create(zone, {
            animation: dragAnimation(),
            draggable: "[data-session-id]",
            forceFallback: true,
            ghostClass: "opacity-40",
            group: { name: "board", pull: true, put: zone !== this.el },
            onEnd: (event) => {
              this.onDrop(event);
            },
            onStart: () => {
              this.dragging = true;
            },
            sort: false,
          });
        },
        destroyed() {
          this.teardown();
        },
        dragging: false,
        mounted() {
          this.setup();
        },
        /** @param {import("sortablejs").SortableEvent} event */
        onDrop(event) {
          this.dragging = false;
          restoreDraggedItem(event);
          if (typeof event.to.dataset.dropzone === "string") {
            this.pushEvent(
              "drop_session",
              {
                day: event.to.dataset.day,
                "session-id": event.item.dataset.sessionId,
                slot: event.to.dataset.slot,
                target: event.to.dataset.dropzone,
              },
              acknowledgePatch,
            );
          }
        },
        setup() {
          this.teardown();
          if (this.el.dataset.readonly === "true") {
            return;
          }
          const tray = document.querySelector('[data-dropzone="tray"]');
          const zones = [this.el, ...htmlElements(this.el, "[data-dropzone]")];
          if (tray instanceof HTMLElement) {
            zones.push(tray);
          }
          this.sorters = zones.map((zone) => this.createSorter(zone));
        },
        /** @type {Sortable[]} */
        sorters: [],
        teardown() {
          for (const sorter of this.sorters) {
            try {
              sorter.destroy();
            } catch {
              // LiveView may remove a drop zone before the hook updates.
            }
          }
          this.sorters = [];
        },
        updated() {
          if (!this.dragging) {
            this.setup();
          }
        },
      });
    </script>
    """
  end

  # Interval lanes keep simultaneous resources visible; row spans convey duration.
  # This geometry is the domain-specific part, inside standard DaisyUI cards.
  defp position(placements) do
    placements
    |> Enum.group_by(& &1.day)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {_day, rows} ->
      {positioned, ends} =
        rows
        |> Enum.sort_by(&{&1.slot, &1.id})
        |> Enum.reduce({[], []}, fn p, {acc, ends} ->
          lane = Enum.find_index(ends, &(&1 <= p.slot)) || length(ends)

          ends =
            if lane == length(ends),
              do: ends ++ [p.slot + p.duration_slots],
              else: List.replace_at(ends, lane, p.slot + p.duration_slots)

          {[{p, lane} | acc], ends}
        end)

      Enum.map(Enum.reverse(positioned), fn {p, lane} -> {p, lane, length(ends)} end)
    end)
  end
end
