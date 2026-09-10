defmodule NeuZeitWeb.UI.TransferList do
  @moduledoc "Moves records between available and selected lists."
  use NeuZeitWeb, :ui_component

  @doc """
  Selects records between available and selected lists using buttons or dragging.

  Used for allowed rooms and attending groups.
  """
  attr :id, :string, required: true
  attr :available, :list, required: true, doc: "%{id:, label:, hint:} not currently selected"
  attr :selected, :list, required: true, doc: "%{id:, label:, hint:} currently selected"
  attr :event, :string, default: "selection_changed"
  attr :available_label, :string, default: nil
  attr :selected_label, :string, default: nil

  def transfer_list(assigns) do
    ~H"""
    <div id={@id} phx-hook=".Draggable" data-event={@event} class="grid gap-4 sm:grid-cols-2">
      <section
        :for={
          {role, label, items} <- [
            {"available", @available_label || gettext("Available"), @available},
            {"selected", @selected_label || gettext("Selected"), @selected}
          ]
        }
        class="card card-border border-base-300 bg-base-100"
      >
        <div class="flex flex-wrap items-center justify-between gap-2 border-b border-base-300 p-4">
          <h3 class="type-heading">{label}</h3>
        </div>
        <ul data-role={role} class="list min-h-24 p-2">
          <li
            :for={item <- items}
            data-id={item.id}
            class="list-row items-center gap-2 p-2 cursor-grab active:cursor-grabbing"
          >
            <div class="list-col-grow min-w-0">
              <p>{item.label}</p>
              <p :if={item[:hint]}>{item[:hint]}</p>
            </div>
            <button
              type="button"
              class="btn"
              data-toggle-member={item.id}
              aria-label={
                if role == "selected",
                  do: gettext("Remove %{name}", name: item.label),
                  else: gettext("Add %{name}", name: item.label)
              }
            >
              {if role == "selected", do: gettext("Remove"), else: gettext("Add")}
            </button>
          </li>
        </ul>
      </section>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Draggable">
      import {
        acknowledgePatch,
        closestHtmlElement,
        defineHook,
        dragAnimation,
        htmlElements,
        restoreDraggedItem,
      } from "@/js/hook-dom.js";
      import Sortable from "sortablejs";

      export default defineHook({
        destroyed() {
          this.el.removeEventListener("click", this.onToggle);
          for (const sorter of this.sorters) {
            sorter.destroy();
          }
        },

        mounted() {
          this.onToggle = this.onToggle.bind(this);
          this.el.addEventListener("click", this.onToggle);
          this.sorters = htmlElements(this.el, "[data-role]").map((list) =>
            Sortable.create(list, {
              animation: dragAnimation(),
              filter: "button",
              forceFallback: true,
              ghostClass: "opacity-40",
              group: this.el.id,
              onEnd: (event) => {
                const selected = this.selectedMembers();
                restoreDraggedItem(event);
                this.sendSelection(selected);
              },
              preventOnFilter: false,
            }),
          );
        },

        /** @param {MouseEvent} event */
        onToggle(event) {
          const button = closestHtmlElement(event.target, "[data-toggle-member]");
          const selected = this.selectedMembers();
          if (button instanceof HTMLElement && typeof button.dataset.toggleMember === "string") {
            const member = button.dataset.toggleMember;
            if (selected.includes(member)) {
              this.sendSelection(selected.filter((value) => value !== member));
            } else {
              this.sendSelection([...selected, member]);
            }
          }
        },

        selectedMembers() {
          return htmlElements(this.el, '[data-role="selected"] [data-id]')
            .map((node) => node.dataset.id)
            .filter((value) => typeof value === "string");
        },

        /** @param {readonly string[]} selected */
        sendSelection(selected) {
          if (typeof this.el.dataset.event !== "string") {
            throw new TypeError("Missing selection event");
          }
          this.pushEvent(this.el.dataset.event, { id: this.el.id, selected }, acknowledgePatch);
        },

        /** @type {Sortable[]} */
        sorters: [],
      });
    </script>
    """
  end
end
