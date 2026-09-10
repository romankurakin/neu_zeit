/** @param {ParentNode} root @param {string} selector */
export const htmlElements = (root, selector) =>
  [...root.querySelectorAll(selector)].filter((element) => element instanceof HTMLElement);

/** @param {EventTarget | null} target @param {string} selector */
export const closestHtmlElement = (target, selector) => {
  if (target instanceof Element) {
    const element = target.closest(selector);
    if (element instanceof HTMLElement) {
      return element;
    }
  }
  return null;
};

/** @param {import("sortablejs").SortableEvent} event */
export const restoreDraggedItem = (event) => {
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

/**
 * Object hooks work across the application and Storybook LiveView runtimes.
 * @template {object} Definition
 * @param {Readonly<Definition> & ThisType<Definition & import("phoenix_live_view").HookInterface>} definition
 */
export const defineHook = (definition) => definition;
