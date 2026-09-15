import { PluginRegistry, TimepickerUI } from "timepicker-ui";
import { WheelPlugin } from "timepicker-ui/plugins/wheel";
import { defineHook } from "./hook-dom";

PluginRegistry.register(WheelPlugin);
const pickers = new WeakMap<HTMLElement, TimepickerUI>();

const createPicker = (root: HTMLElement, input: HTMLInputElement) => {
  const { dataset } = root;
  const picker = new TimepickerUI(input, {
    clock: { type: "24h" },
    labels: {
      announceHour: dataset.labelHours,
      announceMinute: dataset.labelMinutes,
      cancel: dataset.labelCancel,
      hourLabel: dataset.labelHours,
      invalidTimeFormat: dataset.labelInvalid,
      minuteLabel: dataset.labelMinutes,
      ok: dataset.labelDone,
      time: dataset.labelChoose,
      timeLabel: dataset.labelChoose,
    },
    ui: {
      animation: false,
      backdrop: false,
      cssClass: "neu-zeit-time-picker",
      editable: true,
      enableScrollbar: true,
      mode: "compact-wheel",
    },
    wheel: { placement: "auto" },
  });
  picker.on("confirm", () => {
    input.dispatchEvent(new Event("input", { bubbles: true }));
    input.focus();
  });
  picker.create();
  return picker;
};

export default defineHook({
  connect() {
    const input = this.input();
    if (input.disabled || input.readOnly) {
      this.destroyed();
    } else if (!pickers.has(this.el)) {
      pickers.set(this.el, createPicker(this.el, input));
    }
  },
  destroyed() {
    pickers.get(this.el)?.destroy({ keepInputValue: true });
    pickers.delete(this.el);
  },
  input() {
    const input = this.el.querySelector("input");
    if (!(input instanceof HTMLInputElement)) {
      throw new TypeError("Missing time input");
    }
    return input;
  },
  mounted() {
    this.connect();
  },
  updated() {
    this.connect();
  },
});
