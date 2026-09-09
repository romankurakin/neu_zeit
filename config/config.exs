# Compile-time application configuration. Environment-specific overrides load last.

import Config

config :neu_zeit,
  ecto_repos: [NeuZeit.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

config :neu_zeit, NeuZeit.Repo,
  migration_primary_key: [type: :uuid],
  migration_foreign_key: [type: :uuid]

config :neu_zeit, NeuZeitWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: NeuZeitWeb.ErrorHTML, problem: NeuZeitWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: NeuZeit.PubSub,
  live_view: [signing_salt: "PA6Ss/Yw"]

# Serve generated hooks as source modules so browser caches do not hide edits.
colocated_dir = Path.expand("../assets/colocated/#{config_env()}", __DIR__)
config :phoenix_live_view, :colocated_assets, target_directory: colocated_dir

config :volt,
  entry:
    if(config_env() == :prod,
      do: "assets/js/app.js",
      else: ["assets/js/app.js", "assets/js/storybook.js"]
    ),
  root: "assets",
  outdir: "priv/static/assets",
  target: :es2022,
  format: :esm,
  sourcemap: :hidden,
  resolve_dirs: [Mix.Project.deps_path(), Mix.Project.build_path()],
  aliases: %{
    "@" => Path.expand("../assets", __DIR__),
    "phoenix-colocated" => colocated_dir
  },
  tailwind: [
    css: "assets/css/app.css",
    sources: [
      %{base: "lib/", pattern: "**/*.{ex,heex}"},
      %{base: "assets/", pattern: "**/*.{js,ts}"},
      %{base: "storybook/", pattern: "**/*.exs"},
      %{base: "dev/", pattern: "**/*.ex"}
    ]
  ]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

config :mime, :types, %{
  "application/problem+json" => ["problem"]
}

# Load environment overrides after the shared configuration.
import_config "#{config_env()}.exs"
