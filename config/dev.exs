import Config

config :neu_zeit, NeuZeit.Repo,
  username: "postgres",
  password: "postgres",
  hostname: System.get_env("DATABASE_HOST", "localhost"),
  database: "neu_zeit_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# Enable debugging and code reloading for development.
config :neu_zeit, NeuZeitWeb.Endpoint,
  # Development runs in a container. Compose publishes the port on the host
  # loopback interface only, so binding every container interface is safe.
  http: [ip: {0, 0, 0, 0}],
  check_origin: false,
  code_reloader: true,
  reloadable_paths: ["lib", "dev"],
  debug_errors: true,
  secret_key_base: "tr8cskdMtkNUCmRxjtW9e+lWTU+D+XVgIF4ni1fVFjFzQF49odj7CqGN+Q+1xJV/"

config :volt, :server,
  prefix: "/assets",
  watch_dirs: ["assets/", "lib/", "dev/", "storybook/"],
  watch_ignored: ["colocated/test/**", "colocated/prod/**"]

# Watch static and templates for browser reloading.
config :neu_zeit, NeuZeitWeb.Endpoint,
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/neu_zeit_web/(?:controllers|live|components)/.*(ex|heex)$",
      ~r"storybook/.*\.exs$",
      ~r"dev/.*\.ex$"
    ]
  ]

# For local HTTPS certificates, run `mix phx.gen.cert`.
# Use the generated key and certificate in the endpoint :https configuration.

# Enable development-only routes, including the Storybook.
config :neu_zeit, dev_routes: true

# Omit metadata and timestamps from development logs.
config :logger, :default_formatter, format: "[$level] $message\n"

# Include more stack frames in development errors.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime
