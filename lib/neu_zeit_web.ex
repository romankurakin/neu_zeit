defmodule NeuZeitWeb do
  @moduledoc """
  Shared imports and aliases for web modules.

      use NeuZeitWeb, :controller
      use NeuZeitWeb, :html

  Keep quoted expressions limited to imports, uses and aliases.
  Define helper functions in separate modules.
  """

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: NeuZeitWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  @doc """
  Imports for UI component modules.

  General components live in `components/ui`, grouped by component family.
  Scheduling components compose them in `components/scheduling`.
  Use familiar nouns for public components and slots for content and actions.
  DaisyUI owns visual variants. Components own their internal layout.
  Storybook uses the same functions with in-memory fixtures and working events.

  References: https://ui.shadcn.com/docs/components and https://daisyui.com/components/.

  Do not import `html_helpers` here: it imports these modules and would create a cycle.
  """
  def ui_component do
    quote do
      use Phoenix.Component

      use Gettext, backend: NeuZeitWeb.Gettext

      import NeuZeitWeb.CoreComponents

      alias Phoenix.LiveView.JS

      unquote(verified_routes())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      use Gettext, backend: NeuZeitWeb.Gettext

      import Phoenix.HTML
      import NeuZeitWeb.CoreComponents

      import NeuZeitWeb.Scheduling.CheckResults
      import NeuZeitWeb.Scheduling.Diagnostics
      import NeuZeitWeb.Scheduling.Labels
      import NeuZeitWeb.Scheduling.SessionCard
      import NeuZeitWeb.Scheduling.SessionTray
      import NeuZeitWeb.Scheduling.TeachingWeeks
      import NeuZeitWeb.Scheduling.TermCalendar
      import NeuZeitWeb.Scheduling.TimeGrid
      import NeuZeitWeb.Scheduling.Timetable
      import NeuZeitWeb.Scheduling.WeekPicker
      import NeuZeitWeb.UI.Card
      import NeuZeitWeb.UI.DetailsPanel
      import NeuZeitWeb.UI.Dialog
      import NeuZeitWeb.UI.EmptyState
      import NeuZeitWeb.UI.LoadingState
      import NeuZeitWeb.UI.PageHeader
      import NeuZeitWeb.UI.StatCard
      import NeuZeitWeb.UI.Status
      import NeuZeitWeb.UI.Table
      import NeuZeitWeb.UI.Tabs
      import NeuZeitWeb.UI.Toolbar
      import NeuZeitWeb.UI.TransferList

      alias NeuZeitWeb.UI.Errors

      alias Phoenix.LiveView.JS
      alias NeuZeitWeb.Layouts

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: NeuZeitWeb.Endpoint,
        router: NeuZeitWeb.Router,
        statics: NeuZeitWeb.static_paths()
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
