defmodule NeuZeitWeb.Locale do
  @moduledoc """
  Selects the interface language for HTTP requests and LiveViews.

  Supported languages and the default come from `NeuZeit.Config`.
  The selected language is stored in the browser session.
  """

  import Plug.Conn

  @session_key "locale"

  @doc "Returns the supported languages from institution settings."
  def supported, do: NeuZeit.Settings.snapshot().supported_locales

  @doc "Returns the default language from institution settings."
  def default, do: NeuZeit.Settings.snapshot().default_locale

  @doc "Human-readable names for the language switcher."
  def label("de"), do: "Deutsch"
  def label("en"), do: "English"
  def label("ru"), do: "Русский"
  def label(locale), do: String.upcase(locale)

  def init(opts), do: opts

  @doc """
  Plug: resolves the language and applies it to the request process.
  """
  def call(conn, _opts) do
    NeuZeit.Settings.refresh()
    locale = resolve(get_session(conn, @session_key))
    Gettext.put_locale(NeuZeitWeb.Gettext, locale)
    put_session(conn, @session_key, locale)
  end

  @doc """
  Applies the session language to the LiveView process.

  LiveViews use separate processes and do not inherit the HTTP process locale.
  """
  def on_mount(:default, _params, session, socket) do
    NeuZeit.Settings.refresh()
    locale = resolve(session[@session_key])
    Gettext.put_locale(NeuZeitWeb.Gettext, locale)
    {:cont, Phoenix.Component.assign(socket, :locale, locale)}
  end

  @doc """
  Stores a supported language in the session; unsupported values use the default.
  """
  def put(conn, locale) do
    put_session(conn, @session_key, resolve(locale))
  end

  defp resolve(locale) when is_binary(locale) do
    if locale in supported(), do: locale, else: default()
  end

  defp resolve(_locale), do: default()
end
