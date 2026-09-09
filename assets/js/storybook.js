import { hooks as Hooks } from "phoenix-colocated/neu_zeit"

// Storybook owns the LiveSocket.
globalThis.storybook = { Hooks }

const root = document.documentElement
const syncTheme = () => {
  if (root.classList.contains("psb:dark")) {
    root.dataset.theme = "dark"
  } else {
    root.dataset.theme = "light"
  }
}

new MutationObserver(syncTheme).observe(root, { attributeFilter: ["class"], attributes: true })
syncTheme()
