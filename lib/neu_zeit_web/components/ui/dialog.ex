defmodule NeuZeitWeb.UI.Dialog do
  @moduledoc "Native dialogs and action confirmations."
  use NeuZeitWeb, :ui_component

  @doc """
  Renders a confirmation dialog for a pending server-side action.

  Cancel receives initial focus. Escape and backdrop clicks also cancel.
  """
  attr :id, :string, default: "confirm-modal"
  attr :title, :string, required: true
  attr :message, :string, required: true
  attr :confirm_label, :string, default: nil
  attr :cancel_label, :string, default: nil
  attr :on_confirm, :string, required: true
  attr :on_cancel, :string, required: true
  attr :variant, :string, default: "destructive", values: ~w(destructive primary)

  def alert_dialog(assigns) do
    ~H"""
    <.dialog id={@id} title={@title} description={@message} role="alertdialog" on_cancel={@on_cancel}>
      <:actions>
        <.button type="button" phx-click={@on_cancel} autofocus>{@cancel_label || gettext("Cancel")}</.button>
        <.button type="button" variant={@variant} phx-click={@on_confirm}>
          {@confirm_label || gettext("Confirm")}
        </.button>
      </:actions>
    </.dialog>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :on_cancel, :string, required: true
  attr :role, :string, default: "dialog", values: ~w(dialog alertdialog)
  attr :class, :any, default: nil
  slot :actions
  slot :inner_block

  def dialog(assigns) do
    ~H"""
    <dialog
      id={@id}
      role={@role}
      class="modal"
      aria-labelledby={"#{@id}-title"}
      aria-describedby={@description && "#{@id}-description"}
      phx-hook=".NativeDialog"
      phx-mounted={JS.ignore_attributes("open")}
      data-cancel={@on_cancel}
    >
      <div class={["modal-box", @class]}>
        <h2 id={"#{@id}-title"} class="type-title">{@title}</h2>
        <div :if={@description || @inner_block != []} class="mt-4 flex flex-col gap-4">
          <p :if={@description} id={"#{@id}-description"} class="type-detail">{@description}</p>
          {render_slot(@inner_block)}
        </div>
        <div :if={@actions != []} class="modal-action">{render_slot(@actions)}</div>
      </div>
      <button
        type="button"
        class="modal-backdrop"
        phx-click={@on_cancel}
        aria-label={gettext("Cancel")}
        tabindex="-1"
      ></button>
    </dialog>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".NativeDialog">
      import { acknowledgePatch, defineHook } from "@/js/hook-dom";

      export default defineHook({
        destroyed() {
          this.el.removeEventListener("cancel", this.onCancel);
          if (this.el instanceof HTMLDialogElement) {
            this.el.close();
          }
          if (this.previous instanceof HTMLElement && this.previous.isConnected) {
            this.previous.focus({ preventScroll: true });
          }
        },

        mounted() {
          this.previous = document.activeElement;
          this.onCancel = this.onCancel.bind(this);
          this.el.addEventListener("cancel", this.onCancel);
          requestAnimationFrame(() => {
            if (this.el instanceof HTMLDialogElement && this.el.isConnected) {
              this.el.showModal();
              requestAnimationFrame(() => {
                const target = this.el.querySelector("[autofocus]");
                if (target instanceof HTMLElement) {
                  target.focus();
                }
              });
            }
          });
        },

        /** @param {Event} event */
        onCancel(event) {
          event.preventDefault();
          if (typeof this.el.dataset.cancel === "string") {
            this.pushEvent(this.el.dataset.cancel, {}, acknowledgePatch);
          }
        },

        previous: document.activeElement,
      });
    </script>
    """
  end
end
