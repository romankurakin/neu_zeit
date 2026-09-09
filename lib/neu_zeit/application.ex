defmodule NeuZeit.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      NeuZeitWeb.Telemetry,
      NeuZeit.Repo,
      {DNSCluster, query: Application.get_env(:neu_zeit, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: NeuZeit.PubSub},
      NeuZeit.Solver.Runner,
      {Task.Supervisor, name: NeuZeit.Solver.PlanRuns.Tasks},
      NeuZeit.Solver.PlanRuns,
      # Start the endpoint after its dependencies.
      NeuZeitWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: NeuZeit.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Update the endpoint configuration when the application configuration changes.
  @impl true
  def config_change(changed, _new, removed) do
    NeuZeitWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
