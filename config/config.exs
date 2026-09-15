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
      do: "assets/js/app.ts",
      else: ["assets/js/app.ts", "assets/js/storybook.ts"]
    ),
  root: "assets",
  sources: ["{js,vendor}/**/*.ts"],
  ignore: [],
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

config :volt, :lint,
  root: ".",
  sources: ["assets/js/**/*.ts", "assets/vendor/**/*.ts", "assets/colocated/dev/*/*/*.js"],
  ignore: ["assets/colocated/*/*/index.js"],
  plugins: [:typescript, :unicorn, :oxc],
  env: [:browser],
  tsgolint: "node_modules/.bin/tsgolint",
  rules: %{
    "correctness" => :deny,
    "suspicious" => :deny,
    "pedantic" => :deny,
    "perf" => :deny,
    "style" => :deny,
    # Volt requires explicit names for type-aware rules.
    "typescript/await-thenable" => :deny,
    "typescript/no-floating-promises" => :deny,
    "typescript/no-misused-promises" => :deny,
    "typescript/no-unsafe-argument" => :deny,
    "typescript/no-unsafe-assignment" => :deny,
    "typescript/no-unsafe-call" => :deny,
    "typescript/no-unsafe-member-access" => :deny,
    "typescript/no-unsafe-return" => :deny,
    "typescript/restrict-plus-operands" => :deny,
    "typescript/switch-exhaustiveness-check" => :deny,
    "typescript/unbound-method" => :deny,
    # Conflicts with eslint/no-ternary.
    "unicorn/prefer-ternary" => :allow
  },
  overrides: [
    %{
      files: ["assets/colocated/**/*.js"],
      # Phoenix generates these filenames.
      rules: %{"unicorn/filename-case" => :allow}
    },
    %{
      files: ["assets/js/hook-dom.ts"],
      # Match the DOM lookup APIs.
      rules: %{"unicorn/no-null" => :allow}
    },
    %{
      files: ["assets/vendor/heroicons.ts"],
      env: %{browser: false, node: true}
    }
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
