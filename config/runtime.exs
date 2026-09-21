import Config

# Runtime configuration runs after compilation and before startup, including releases.
# Read runtime environment variables here; put compile-time options in config.exs.

# To start the HTTP server in a release:
#
#     PHX_SERVER=true bin/neu_zeit start
if System.get_env("PHX_SERVER") do
  config :neu_zeit, NeuZeitWeb.Endpoint, server: true
end

config :neu_zeit, NeuZeitWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  config :neu_zeit,
    solver_workers:
      String.to_integer(
        System.get_env("SOLVER_WORKERS") || "#{min(System.schedulers_online(), 8)}"
      ),
    solver_max_concurrency: String.to_integer(System.get_env("SOLVER_MAX_CONCURRENCY") || "1")

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :neu_zeit, NeuZeit.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  # Read the production signing secret from the environment.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :neu_zeit, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :neu_zeit, NeuZeitWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Bind HTTP on all IPv6 interfaces. Use {0, 0, 0, 0, 0, 0, 0, 1} for loopback access.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # For endpoint TLS, configure :https with the port, keyfile and certfile.
  # See https://hexdocs.pm/plug/Plug.SSL.html for TLS and redirect options.
end
