defmodule Algedonia.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        AlgedoniaWeb.Telemetry,
        Algedonia.Repo,
        {DNSCluster, query: Application.get_env(:algedonia, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Algedonia.PubSub},
        Algedonia.Presence
      ] ++
        [
          {Registry, keys: :unique, name: Algedonia.Terminals.Registry},
          {Algedonia.Terminals.TerminalSupervisor, name: Algedonia.Terminals.TerminalSupervisor}
        ] ++
        if(Application.get_env(:algedonia, :start_daemon_monitor, true),
          do: [Algedonia.DaemonMonitor],
          else: []
        ) ++
        if(Application.get_env(:algedonia, :start_orchestrator, true),
          do: [Algedonia.TaskLoopOrchestrator, Algedonia.ReviewLoop],
          else: []
        ) ++
        [AlgedoniaWeb.Endpoint]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Algedonia.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AlgedoniaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
