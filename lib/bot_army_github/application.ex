defmodule BotArmyGithub.Application do
  @moduledoc """
  GitHub Bot application supervisor.

  Follows bot army pattern with environment-aware startup:
  - Repo not started in :test (tests inject mocks)
  - PulsePublisher sends `system.health` liveness every 30s and rich `bot.<service>.pulse` every 30 minutes
  - Workers not started in :test (gated by @env)

  Observability: see `PulsePublisher` — fleet UIs keyed on Synapse hydration should use `system.health` freshness (90s), not pulse interval alone.
  """

  use Application

  @dialyzer {:nowarn_function,
             [
               {:maybe_add_repo, 1},
               {:maybe_add_pulse_publisher, 1},
               {:maybe_add_consumer, 1},
               {:maybe_add_http_server, 1},
               {:maybe_add_workers, 1},
               {:maybe_add_docs_search_responder, 1}
             ]}

  @env Mix.env()

  @impl true
  def start(_type, _args) do
    # Note: BotArmyLibraryRuntime.Telemetry and BotArmyLibraryRuntime.NATS.Connection are started
    # by bot_army_runtime automatically — do not add them here.

    children =
      []
      |> maybe_add_repo()
      |> maybe_add_pulse_publisher()
      |> maybe_add_consumer()
      |> maybe_add_http_server()
      |> maybe_add_workers()
      |> maybe_add_docs_search_responder()

    opts = [strategy: :one_for_one, name: BotArmyGithub.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_add_repo(children) do
    if @env == :test do
      children
    else
      [{BotArmyGithub.Repo, []} | children]
    end
  end

  defp maybe_add_pulse_publisher(children) do
    if @env == :test do
      children
    else
      [{BotArmyGithub.PulsePublisher, []} | children]
    end
  end

  defp maybe_add_http_server(children) do
    if @env == :test do
      children
    else
      http_port = System.get_env("BOT_ARMY_GITHUB_HTTP_PORT", "39904") |> String.to_integer()

      [
        {
          Plug.Cowboy,
          [scheme: :http, plug: BotArmyGithub.WebhookReceiver, options: [port: http_port]]
        }
        | children
      ]
    end
  end

  defp maybe_add_consumer(children) do
    if @env == :test do
      children
    else
      [{BotArmyGithub.NATS.Consumer, []} | children]
    end
  end

  defp maybe_add_workers(children) do
    if @env == :test do
      children
    else
      repos = Application.get_env(:bot_army_github, :sync_repos, [])

      poll_interval =
        Application.get_env(:bot_army_github, :sync_poll_interval_ms, :timer.minutes(15))

      worker = {BotArmyGithub.IssueSyncWorker, [repos: repos, poll_interval_ms: poll_interval]}
      [worker | children]
    end
  end

  defp maybe_add_docs_search_responder(children) do
    if @env == :test do
      children
    else
      repo_path =
        Application.get_env(:bot_army_github, :ingestor_repo_path, "/Users/abby/code/elixir_bots")

      [{BotArmyGithub.NATS.DocsSearchResponder, [repo_path: repo_path]} | children]
    end
  end
end
