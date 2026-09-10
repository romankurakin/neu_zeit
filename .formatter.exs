[
  plugins: [Phoenix.LiveView.HTMLFormatter, NeuZeitWeb.JavaScriptFormatter],
  tag_formatters: %{script: NeuZeitWeb.JavaScriptFormatter},
  import_deps: [:ecto, :ecto_sql, :phoenix],
  subdirectories: ["priv/*/migrations"],
  inputs: [
    "*.{ex,exs}",
    "{config,lib,test}/**/*.{ex,exs}",
    "{lib,test}/**/*.heex",
    "assets/{js,vendor}/**/*.{js,mjs}",
    "priv/*/seeds.exs",
    "dev/**/*.ex",
    "storybook/**/*.exs"
  ]
]
