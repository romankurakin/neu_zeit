import type { HookInterface } from "phoenix_live_view";
import type { SortableEvent } from "sortablejs";

export const htmlElements = (root: ParentNode, selector: string) =>
  [...root.querySelectorAll(selector)].filter((element) => element instanceof HTMLElement);

export const closestHtmlElement = (target: EventTarget | null, selector: string) => {
  if (target instanceof Element) {
    const element = target.closest(selector);
    if (element instanceof HTMLElement) {
      return element;
    }
  }
  return null;
};

export const restoreDraggedItem = (event: SortableEvent) => {
  if (typeof event.oldIndex === "number") {
    event.from.insertBefore(event.item, event.from.children.item(event.oldIndex));
  } else {
    event.from.append(event.item);
  }
};

export const acknowledgePatch = () => {
  // LiveView applies the server reply through its DOM patch.
};

const animationDisabled = 0;
const animationDuration = 120;

/** Reordering time in milliseconds. Readers who ask for less motion get none. */
export const dragAnimation = () => {
  if (globalThis.matchMedia("(prefers-reduced-motion: reduce)").matches) {
    return animationDisabled;
  }
  return animationDuration;
};

// Object hooks work across the application and Storybook LiveView runtimes.
export const defineHook = <Definition extends object>(
  definition: Readonly<Definition> & ThisType<Definition & HookInterface>,
) => definition;
