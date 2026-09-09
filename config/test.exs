import Config

# MIX_TEST_PARTITION selects a separate database for each test partition.
config :neu_zeit, NeuZeit.Repo,
  username: "postgres",
  password: "postgres",
  hostname: System.get_env("DATABASE_HOST", "localhost"),
  database: "neu_zeit_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Disable the HTTP server in tests.
config :neu_zeit, NeuZeitWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "BTdgD+SXm9tH6OjvWNA3ww8snir/J4HO1E8xyUsBESKU4r41nvpjJXasuqZb9OvS",
  server: false

# Enable Storybook routes for component interaction tests.
config :neu_zeit, dev_routes: true

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime

# Sort URL query parameters for stable comparisons in tests.
config :phoenix,
  sort_verified_routes_query_params: true
