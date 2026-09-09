defmodule NeuZeitWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :neu_zeit

  # Session cookies are signed but not encrypted. Their contents can be read.
  # Set `:encryption_salt` to encrypt them.
  @session_options [
    store: :cookie,
    key: "_neu_zeit_key",
    signing_salt: "7y4+3vEJ",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  # Code reloading is controlled by the endpoint :code_reloader option.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket,
      websocket: true,
      longpoll: true

    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    # Tailwind writes CSS to priv/static; Volt serves JavaScript from source.
    plug Plug.Static,
      at: "/assets/css",
      from: {:neu_zeit, "priv/static/assets/css"},
      gzip: false

    plug Volt.DevServer, root: "assets"
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :neu_zeit
  end

  # Serves priv/static at the root URL. Enables compressed assets when code reloading is off.
  plug Plug.Static,
    at: "/",
    from: :neu_zeit,
    gzip: not code_reloading?,
    only: NeuZeitWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug NeuZeitWeb.Router
end
