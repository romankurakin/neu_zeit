import "phoenix_html";
import { LiveSocket } from "phoenix_live_view";
import { Socket } from "phoenix";
import { hooks as colocatedHooks } from "phoenix-colocated/neu_zeit";
import topbar from "topbar";

const csrfToken = () => {
  const meta = document.querySelector("meta[name='csrf-token']");
  if (!(meta instanceof HTMLMetaElement) || meta.content === "") {
    throw new Error("Missing CSRF token");
  }
  return meta.content;
};
const delays = { progress: 300, reconnect: 2500 };
const liveSocket = new LiveSocket("/live", Socket, {
  hooks: colocatedHooks,
  longPollFallbackMs: delays.reconnect,
  params: () => ({
    _csrf_token: csrfToken(),
    navigation_term: sessionStorage.getItem("navigation-term") ?? "",
  }),
});

globalThis.addEventListener("phx:page-loading-start", () => {
  const primary = getComputedStyle(document.documentElement)
    .getPropertyValue("--color-primary")
    .trim();
  topbar.config({ barColors: { 0: primary }, shadowBlur: 0 });
  topbar.show(delays.progress);
});
globalThis.addEventListener("phx:page-loading-stop", () => {
  topbar.hide();
});

liveSocket.connect();
globalThis.liveSocket = liveSocket;

if (import.meta.env.DEV) {
  globalThis.addEventListener("phx:live_reload:attached", ({ detail: reloader }) => {
    reloader.enableServerLogs();
    // Phoenix keeps these shortcuts scoped to the configured PLUG_EDITOR.
    let keyDown = "";
    globalThis.addEventListener("keydown", (event) => {
      keyDown = event.key;
    });
    globalThis.addEventListener("keyup", () => {
      keyDown = "";
    });
    globalThis.addEventListener(
      "click",
      (event) => {
        if (!(event.target instanceof Element)) {
          return;
        }
        if (keyDown === "c" || keyDown === "d") {
          event.preventDefault();
          event.stopImmediatePropagation();
          if (keyDown === "c") {
            reloader.openEditorAtCaller(event.target);
          } else {
            reloader.openEditorAtDef(event.target);
          }
        }
      },
      true,
    );
    globalThis.liveReloader = reloader;
  });
}
