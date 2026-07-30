# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :neu_zeit,
  ecto_repos: [NeuZeit.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

config :neu_zeit, NeuZeit.Repo,
  migration_primary_key: [type: :uuid],
  migration_foreign_key: [type: :uuid]

# Configure the endpoint
config :neu_zeit, NeuZeitWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [problem: NeuZeitWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: NeuZeit.PubSub,
  live_view: [signing_salt: "PA6Ss/Yw"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :mime, :types, %{
  "application/problem+json" => ["problem"]
}

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
