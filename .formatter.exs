[
  plugins: [Phoenix.LiveView.HTMLFormatter, Volt.Formatter],
  tag_formatters: %{script: NeuZeitWeb.JavaScriptFormatter},
  import_deps: [:ecto, :ecto_sql, :phoenix],
  subdirectories: ["priv/*/migrations"],
  inputs: [
    "*.{ex,exs}",
    "{config,lib,test}/**/*.{ex,exs}",
    "{lib,test}/**/*.heex",
    "assets/{js,vendor}/**/*.ts",
    "priv/*/seeds.exs",
    "dev/**/*.ex",
    "storybook/**/*.exs"
  ]
]
