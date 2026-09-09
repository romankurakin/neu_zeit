interface LiveReloader {
  enableServerLogs(): void
  openEditorAtCaller(target: Element): void
  openEditorAtDef(target: Element): void
}

declare var liveSocket: import("phoenix_live_view").LiveSocket
declare var liveReloader: LiveReloader
declare var storybook: { Hooks: import("phoenix_live_view").HooksOptions }

interface Window {
  liveSocket: import("phoenix_live_view").LiveSocket
  liveReloader: LiveReloader
  storybook: { Hooks: import("phoenix_live_view").HooksOptions }
}

interface WindowEventMap {
  "phx:live_reload:attached": CustomEvent<LiveReloader>
}

interface ImportMeta {
  env: { DEV: boolean }
}

declare module "phoenix_html" { }
