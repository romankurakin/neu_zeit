defmodule NeuZeitWeb.Layouts do
  @moduledoc """
  Page layouts and shared navigation controls.
  """
  use NeuZeitWeb, :html

  # Embeds layout templates, including the root HTML document.
  embed_templates "layouts/*"

  @doc """
  Renders the administrator layout, navigation and flash messages.

  Navigation is a list of `%{title: String.t(), items: [item]}`.
  Each item has `:label`, `:path` and `:icon`, with an optional `:badge` count.
  The sidebar becomes a drawer on narrow screens.
  """
  attr :nav, :list, default: []
  attr :current_path, :string, default: nil
  attr :terms, :list, default: []
  attr :current_term, :map, default: nil
  attr :flash, :map, required: true
  attr :page_path, :string, default: nil
  slot :inner_block, required: true

  def app(assigns) do
    assigns = assign(assigns, :institution, NeuZeit.Settings.snapshot())

    ~H"""
    <div
      id="app-drawer"
      class="drawer lg:drawer-open"
      data-term-id={@current_term && @current_term.id}
      phx-hook=".Navigation"
    >
      <input id="nav-drawer" type="checkbox" tabindex="-1" aria-hidden="true" class="drawer-toggle" />

      <div class="drawer-content min-w-0 flex min-h-dvh flex-col bg-base-200">
        <header class="navbar sticky top-0 z-30 gap-2 border-b border-base-300 bg-base-100 px-4">
          <button
            id="nav-toggle"
            type="button"
            aria-expanded="false"
            aria-controls="main-navigation"
            phx-click={
              JS.toggle_class("drawer-open", to: "#app-drawer")
              |> JS.toggle_attribute({"aria-expanded", "true", "false"}, to: "#nav-toggle")
              |> JS.focus(to: "#nav-close")
            }
            aria-label={gettext("Open navigation")}
            class="btn btn-square btn-ghost lg:hidden"
          >
            <.icon name="hero-bars-3" class="size-5" />
          </button>

          <div class="flex-1 min-w-0">
            <.term_switcher terms={@terms} current_term={@current_term} />
          </div>

          <.locale_switcher current_path={@page_path || @current_path} />
          <.theme_toggle />
        </header>

        <main
          id="main-content"
          data-time-zone={@institution.timezone}
          phx-hook=".LocalDates"
          class="flex-1 min-w-0 p-4"
        >
          {render_slot(@inner_block)}
        </main>
      </div>

      <div class="drawer-side z-40">
        <%!-- Open beside the content, the panel sits in flow, where an inline overlay adds a line box. --%>
        <button
          type="button"
          tabindex="-1"
          aria-label={gettext("Close navigation")}
          class="drawer-overlay block"
          phx-click={close_navigation()}
        ></button>

        <nav
          id="main-navigation"
          phx-window-keydown={JS.exec("phx-click", to: "#app-drawer.drawer-open #nav-close")}
          phx-key="escape"
          class="flex min-h-full w-72 flex-col border-r border-base-300 bg-base-100"
        >
          <div class="flex h-16 items-center gap-2 border-b border-base-300 px-4">
            <.icon name="hero-calendar-days" class="size-5 text-primary" />
            <div class="min-w-0">
              <span class="font-semibold">NeuZeit</span>
              <div class="truncate type-detail" title={@institution.name}>{@institution.name}</div>
            </div>
            <button
              id="nav-close"
              type="button"
              class="btn btn-ghost btn-square ml-auto lg:hidden"
              phx-click={close_navigation()}
              aria-label={gettext("Close navigation")}
            ><.icon name="hero-x-mark" class="size-5" /></button>
          </div>

          <ul class="menu w-full grow gap-1 px-3 py-4">
            <%= for section <- @nav do %>
              <li class="menu-title type-detail">{section.title}</li>
              <li :for={item <- section.items}>
                <.link
                  :if={item.path}
                  navigate={item.path}
                  aria-current={NeuZeitWeb.Nav.active?(item.path, @current_path) && "page"}
                  class={[
                    "justify-between",
                    NeuZeitWeb.Nav.active?(item.path, @current_path) && "menu-active"
                  ]}
                >
                  <span class="flex items-center gap-2">
                    <.icon name={item.icon} class="size-4" />
                    {item.label}
                  </span>
                  <span :if={item[:badge] not in [nil, 0]} class="badge badge-md badge-warning">
                    {item[:badge]}
                  </span>
                </.link>
                <span :if={is_nil(item.path)} aria-disabled="true" class="menu-disabled">
                  <span class="flex items-center gap-2"><.icon name={item.icon} class="size-4" />{item.label}</span>
                </span>
              </li>
            <% end %>
          </ul>
        </nav>
      </div>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".Navigation">
      import { defineHook } from "@/js/hook-dom";

      export default defineHook({
        mounted() {
          this.updated();
        },

        updated() {
          sessionStorage.setItem("navigation-term", this.el.dataset.termId ?? "");
        },
      });
    </script>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".LocalDates">
      import { defineHook } from "@/js/hook-dom";

      // The root layout installs the formatter and runs it before the first paint.
      // A patch drops the ready mark, so every replaced date is written again.
      export default defineHook({
        mounted() {
          globalThis.formatDates(this.el);
        },
        updated() {
          globalThis.formatDates(this.el);
        },
      });
    </script>

    <.flash_group flash={@flash} />
    """
  end

  defp close_navigation do
    JS.remove_class("drawer-open", to: "#app-drawer")
    |> JS.set_attribute({"aria-expanded", "false"}, to: "#nav-toggle")
    |> JS.focus(to: "#nav-toggle")
  end

  attr :current_path, :string, default: nil

  defp locale_switcher(assigns) do
    assigns =
      assigns
      |> assign(:locales, NeuZeitWeb.Locale.supported())
      |> assign(:current, Gettext.get_locale(NeuZeitWeb.Gettext))

    ~H"""
    <form action={~p"/locale"} method="post" class="flex items-center">
      <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
      <input type="hidden" name="return_to" value={@current_path} />
      <label for="locale-switcher" class="sr-only">{gettext("Language")}</label>
      <select
        id="locale-switcher"
        name="locale"
        class="select select-ghost w-auto"
        onchange="this.form.submit()"
      >
        <option :for={locale <- @locales} value={locale} selected={locale == @current}>
          {NeuZeitWeb.Locale.label(locale)}
        </option>
      </select>
    </form>
    """
  end

  attr :terms, :list, required: true
  attr :current_term, :map, default: nil

  defp term_switcher(%{terms: []} = assigns) do
    ~H"""
    <.link navigate={~p"/terms"} class="btn btn-ghost">{gettext("Terms")}</.link>
    """
  end

  defp term_switcher(assigns) do
    ~H"""
    <form id="term-switcher-form" phx-change="switch_term" class="flex min-w-0 items-center gap-2">
      <label for="term-switcher" class="sr-only">{gettext("Current term")}</label>
      <select id="term-switcher" name="term_id" class="select select-ghost font-semibold max-w-full">
        <option
          :for={term <- @terms}
          value={term.id}
          selected={@current_term && term.id == @current_term.id}
        >
          {term.name}
        </option>
      </select>
    </form>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("Reconnecting to the server")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
        loading
      />

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("The page could not be updated")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
        loading
      />
    </div>
    """
  end

  @doc """
  Renders the system, light and dark theme controls.

  `root.html.heex` applies the stored choice before the page is displayed.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div id="theme-toggle" class="join" phx-hook=".ThemeToggle">
      <button
        :for={
          {theme, icon, label} <- [
            {"system", "hero-computer-desktop", gettext("Follow the system theme")},
            {"light", "hero-sun", gettext("Light theme")},
            {"dark", "hero-moon", gettext("Dark theme")}
          ]
        }
        type="button"
        class="btn btn-square join-item"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme={theme}
        aria-label={label}
        aria-pressed="false"
        title={label}
      >
        <.icon name={icon} class="size-4" />
      </button>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ThemeToggle">
      import { defineHook, htmlElements } from "@/js/hook-dom";

      export default defineHook({
        destroyed() {
          globalThis.removeEventListener("phx:theme-changed", this.syncTheme);
        },

        mounted() {
          this.syncTheme = this.syncTheme.bind(this);
          globalThis.addEventListener("phx:theme-changed", this.syncTheme);
          this.syncTheme();
        },

        syncTheme() {
          const selected = document.documentElement.dataset.theme ?? "system";
          for (const button of htmlElements(this.el, "[data-phx-theme]")) {
            const active = button.dataset.phxTheme === selected;
            button.classList.toggle("btn-neutral", active);
            button.setAttribute("aria-pressed", String(active));
          }
        },

        updated() {
          this.syncTheme();
        },
      });
    </script>
    """
  end
end
