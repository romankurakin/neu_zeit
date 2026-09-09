import Config

# Redirect HTTP to HTTPS and enable HSTS. Configure :force_ssl at compile time.
config :neu_zeit, NeuZeitWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [
      hosts: ["localhost", "127.0.0.1"]
    ]
  ]

config :logger, level: :info

# Production environment variables are read in config/runtime.exs.
