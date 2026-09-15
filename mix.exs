defmodule NeuZeit.MixProject do
  use Mix.Project

  def project do
    [
      app: :neu_zeit,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      # Test compilation must not overwrite native libraries loaded by the dev server.
      deps_path: if(Mix.env() == :test, do: "_build/test/deps", else: "deps"),
      start_permanent: Mix.env() == :prod,
      dialyzer: [plt_add_apps: [:mix]],
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      phoenix_live_view: [colocated_assets: [node_modules_path: "node_modules"]],
      listeners: [Phoenix.CodeReloader]
    ]
  end

  def application do
    [
      mod: {NeuZeit.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [ci: :test, precommit: :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "dev", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:phoenix_ecto, "~> 4.7"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_live_reload, "~> 1.7", only: :dev},
      {:phoenix_storybook, "~> 1.4", only: [:dev, :test]},
      {:lazy_html, "~> 0.1", only: :test},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:volt, "~> 0.18.1"},
      {:npm, "~> 0.7", runtime: false},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.22"},
      {:telemetry_metrics, "~> 1.2"},
      {:telemetry_poller, "~> 1.3"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:dns_cluster, "~> 0.3"},
      {:bandit, "~> 1.12"}
    ]
  end

  defp aliases do
    [
      setup: [
        "deps.get",
        "cmd env MIX_ENV=test mix deps.get --check-locked",
        "ecto.setup",
        "assets.setup",
        "assets.build"
      ],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["npm.ci"],
      "assets.build": ["compile", "volt.build --tailwind"],
      "assets.lint": [
        "cmd env MIX_ENV=dev mix compile",
        "cmd env MIX_ENV=dev mix volt.js.check --type-aware --type-check"
      ],
      "assets.deploy": [
        "compile",
        "volt.build --tailwind",
        "phx.digest"
      ],
      lint: [
        "assets.lint",
        "cmd uv run --locked --project priv/solver ruff check --config priv/solver/pyproject.toml priv/solver"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "lint",
        "test"
      ],
      # The precommit steps, without writing to the working tree. CI runs this.
      ci: [
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "format --check-formatted",
        "lint",
        "test"
      ]
    ]
  end
end
