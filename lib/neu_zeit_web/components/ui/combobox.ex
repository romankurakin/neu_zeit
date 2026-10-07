defmodule NeuZeitWeb.UI.Combobox do
  @moduledoc "A select with a search box, for lists too long to scroll."
  use NeuZeitWeb, :ui_component

  @doc """
  Renders a single-choice field whose options are filtered by typing.

  The chosen value travels in a hidden text input, so the form sees the field
  as a select would present it and the field stays untouched until a choice. The text box shows the chosen label and filters the
  list. Enter or a click chooses. Escape closes the list. Leaving the box with
  text that matches no option restores the previous choice.

  ## Example

      <.combobox
        field={@form[:teacher_id]}
        label={gettext("Teacher")}
        prompt={gettext("Choose a teacher")}
        options={Enum.map(@teachers, &{&1.name, &1.id})}
      />
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :prompt, :string, default: nil, doc: "placeholder while nothing is chosen"
  attr :options, :list, required: true, doc: "{label, value} pairs"
  attr :disabled, :boolean, default: false
  attr :rest, :global, include: ~w(required autofocus)

  def combobox(assigns) do
    errors = if Phoenix.Component.used_input?(assigns.field), do: assigns.field.errors, else: []
    value = to_string(assigns.field.value || "")

    assigns =
      assigns
      |> assign(:errors, Enum.map(errors, &NeuZeitWeb.CoreComponents.translate_error/1))
      |> assign(:value, value)
      |> assign(:id, "#{assigns.field.id}-combobox")
      |> assign(:chosen_label, chosen_label(assigns.options, value))

    ~H"""
    <div id={@id} phx-hook=".Combobox" class="fieldset type-detail">
      <%!-- A text input, hidden: type=hidden would count as touched before the user chooses. --%>
      <input
        type="text"
        id={@field.id}
        name={@field.name}
        value={@value}
        data-role="value"
        hidden
        tabindex="-1"
        aria-hidden="true"
      />
      <label for={"#{@id}-input"}>
        <span class="label mb-1">{@label}</span>
        <div class="relative">
          <input
            type="text"
            id={"#{@id}-input"}
            role="combobox"
            aria-expanded="false"
            aria-controls={"#{@id}-list"}
            aria-autocomplete="list"
            autocomplete="off"
            data-role="search"
            disabled={@disabled}
            value={@chosen_label}
            placeholder={@prompt}
            class={["input w-full pr-10", @errors != [] && "input-error"]}
            {@rest}
          />
          <button
            type="button"
            data-role="clear"
            class={[
              "btn btn-ghost btn-square btn-sm absolute right-1 top-1",
              @value == "" && "hidden"
            ]}
            aria-label={gettext("Clear")}
            tabindex="-1"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
          <ul
            id={"#{@id}-list"}
            role="listbox"
            hidden
            phx-mounted={JS.ignore_attributes("hidden")}
            class="menu absolute left-0 right-0 top-full z-20 mt-1 max-h-64 flex-nowrap overflow-y-auto rounded-box border border-base-300 bg-base-100 shadow-lg"
          >
            <li
              :for={{label, option} <- @options}
              role="option"
              data-value={option}
              data-label={label}
            >
              <button type="button" tabindex="-1">{label}</button>
            </li>
            <li data-role="empty" hidden class="menu-disabled">
              <span>{gettext("No matches")}</span>
            </li>
          </ul>
        </div>
      </label>
      <.error :for={message <- @errors}>{message}</.error>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Combobox">
      import { defineHook, htmlElements } from "@/js/hook-dom";

      /**
       * @param {ParentNode} root
       * @param {string} selector
       * @param {string} what
       */
      const required = (root, selector, what) => {
        const element = root.querySelector(selector);
        if (!(element instanceof HTMLElement)) {
          throw new TypeError(`Missing ${what}`);
        }
        return element;
      };

      /** @param {HTMLElement} element */
      const asInput = (element) => {
        if (!(element instanceof HTMLInputElement)) {
          throw new TypeError("Expected an input");
        }
        return element;
      };

      /** How long a click on an option may take after the search box loses focus. */
      const blurDelay = 150;
      const none = 0;
      const forward = 1;
      const backward = -1;

      /** @param {HTMLElement} option @param {string} needle */
      const matches = (option, needle) =>
        needle === "" || (option.dataset.label ?? "").toLowerCase().includes(needle);

      /** @param {HTMLElement[]} options @param {string} value */
      const optionFor = (options, value) => options.find((option) => option.dataset.value === value);

      export default defineHook({
        /** Hides options whose label misses the query. @param {string} query @param {boolean} open */
        applySearch(query, open) {
          const needle = query.trim().toLowerCase();
          let shown = none;
          for (const option of this.options()) {
            option.hidden = !matches(option, needle);
            option.removeAttribute("aria-selected");
            if (!option.hidden) {
              shown += forward;
            }
          }
          this.empty().hidden = shown > none;
          if (open) {
            this.open();
          }
        },

        bindSearch() {
          const search = this.search();
          search.addEventListener("input", () => {
            this.applySearch(search.value, true);
          });
          search.addEventListener("focus", () => {
            this.applySearch("", true);
          });
          search.addEventListener("keydown", (event) => {
            this.onKey(event);
          });
          search.addEventListener("blur", () => {
            this.restore();
          });
        },

        /** Writes the choice and tells the form. @param {HTMLElement} option */
        choose(option) {
          this.setValue(option.dataset.value ?? "", option.dataset.label ?? "");
          this.close();
        },

        clearButton() {
          return required(this.el, '[data-role="clear"]', "clear button");
        },

        close() {
          this.list().hidden = true;
          this.search().setAttribute("aria-expanded", "false");
        },

        destroyed() {
          document.removeEventListener("pointerdown", this.onOutside);
        },

        empty() {
          return required(this.el, '[data-role="empty"]', "empty row");
        },

        hidden() {
          return asInput(required(this.el, '[data-role="value"]', "value input"));
        },

        /** Marks one option as the keyboard choice. @param {HTMLElement | undefined} next */
        highlight(next) {
          for (const option of this.options()) {
            option.removeAttribute("aria-selected");
          }
          if (next) {
            next.setAttribute("aria-selected", "true");
            next.scrollIntoView({ block: "nearest" });
          }
        },

        /** The list is open unless the hook hid it. */
        isOpen() {
          return this.list().hidden === false;
        },

        list() {
          return required(this.el, "[role=listbox]", "list");
        },

        mounted() {
          this.onOutside = this.onOutside.bind(this);
          document.addEventListener("pointerdown", this.onOutside);
          this.bindSearch();
          this.list().addEventListener("click", (event) => {
            if (event.target instanceof Element) {
              const option = event.target.closest("[data-value]");
              if (option instanceof HTMLElement) {
                this.choose(option);
              }
            }
          });
          this.clearButton().addEventListener("click", () => {
            this.setValue("", "");
            this.search().focus();
          });
        },

        /** Moves the highlight through the shown options. @param {number} step */
        moveSelection(step) {
          if (!this.isOpen()) {
            this.applySearch(this.search().value, true);
          }
          const visible = this.visible();
          const index = visible.findIndex((option) => option.hasAttribute("aria-selected"));
          this.highlight(visible[(index + step + visible.length) % visible.length]);
        },

        /** @param {KeyboardEvent} event */
        onKey(event) {
          if (event.key === "ArrowDown") {
            event.preventDefault();
            this.moveSelection(forward);
          } else if (event.key === "ArrowUp") {
            event.preventDefault();
            this.moveSelection(backward);
          } else if (event.key === "Enter" && this.isOpen()) {
            this.pickSelection(event);
          } else if (event.key === "Escape" && this.isOpen()) {
            event.preventDefault();
            event.stopPropagation();
            this.restore();
          }
        },

        /** @param {PointerEvent} event */
        onOutside(event) {
          if (!(event.target instanceof Node) || !this.el.contains(event.target)) {
            this.restore();
          }
        },

        open() {
          this.list().hidden = false;
          this.search().setAttribute("aria-expanded", "true");
        },

        options() {
          return htmlElements(this.el, "[data-value]");
        },

        /** Enter takes the highlighted option, or the only one left. @param {KeyboardEvent} event */
        pickSelection(event) {
          const visible = this.visible();
          let pick = visible.find((option) => option.hasAttribute("aria-selected"));
          if (!pick && visible.length === forward) {
            [pick] = visible;
          }
          if (pick) {
            event.preventDefault();
            this.choose(pick);
          }
        },

        /** The search box shows the choice again when the typed text chose nothing. */
        restore() {
          globalThis.setTimeout(() => {
            if (!this.isOpen()) {
              return;
            }
            const { value } = this.hidden();
            this.search().value = optionFor(this.options(), value)?.dataset.label ?? "";
            this.close();
          }, blurDelay);
        },

        search() {
          return asInput(required(this.el, '[data-role="search"]', "search box"));
        },

        /** @param {string} value @param {string} label */
        setValue(value, label) {
          const hidden = this.hidden();
          this.search().value = label;
          this.clearButton().classList.toggle("hidden", value === "");
          if (hidden.value !== value) {
            hidden.value = value;
            hidden.dispatchEvent(new Event("input", { bubbles: true }));
          }
        },

        /** A patch rewrites the options, so the search and the shown label are applied again. */
        updated() {
          const focused = document.activeElement === this.search();
          const { value } = this.hidden();
          if (this.isOpen()) {
            this.applySearch(this.search().value, true);
          } else if (!focused) {
            this.search().value = optionFor(this.options(), value)?.dataset.label ?? "";
          }
          this.clearButton().classList.toggle("hidden", value === "");
        },

        visible() {
          return this.options().filter((option) => option.hidden === false);
        },
      });
    </script>
    """
  end

  defp chosen_label(_options, ""), do: ""

  defp chosen_label(options, value) do
    case Enum.find(options, fn {_label, option} -> to_string(option) == value end) do
      {label, _option} -> label
      nil -> ""
    end
  end
end
