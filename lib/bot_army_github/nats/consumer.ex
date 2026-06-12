defmodule BotArmyGithub.NATS.Consumer do
  @moduledoc "Consumes GitHub webhook events and forwards them to GTD inbox."

  use GenServer
  require Logger

  @reconnect_delay_ms 5000
  @version Mix.Project.config()[:version]

  @subjects [
    # Webhook events (inbound, published by webhook receiver)
    %{subject: "github.pr.opened", type: :subscribe, description: "GitHub PR opened"},
    %{subject: "github.pr.reopened", type: :subscribe, description: "GitHub PR reopened"},
    %{
      subject: "github.pr.review_requested",
      type: :subscribe,
      description: "GitHub PR review requested"
    },
    %{subject: "github.pr.merged", type: :subscribe, description: "GitHub PR merged"},
    %{subject: "github.issue.opened", type: :subscribe, description: "GitHub issue opened"},
    %{subject: "github.issue.closed", type: :subscribe, description: "GitHub issue closed"},
    %{subject: "github.ci.failed", type: :subscribe, description: "GitHub CI workflow failed"},
    %{subject: "github.ci.passed", type: :subscribe, description: "GitHub CI workflow passed"},
    # Query subjects (request/reply for GitHub data)
    %{subject: "github.pr.get", type: :responder, description: "Get PR details"},
    %{subject: "github.issue.list", type: :responder, description: "List issues"},
    %{subject: "github.repo.file", type: :responder, description: "Get file from repo"},
    %{subject: "github.ci.status", type: :responder, description: "Get CI status"},
    # Write subjects with intent veto (request/reply)
    %{subject: "github.pr.comment", type: :responder, description: "Comment on PR"},
    %{subject: "github.issue.create", type: :responder, description: "Create issue"},
    %{subject: "github.issue.close", type: :responder, description: "Close issue"},
    %{subject: "github.pr.approve", type: :responder, description: "Approve PR"},
    # Issue sync and linkage
    %{subject: "github.issue.sync", type: :responder, description: "Sync issues from repo"},
    %{subject: "github.issue.link_task", type: :responder, description: "Link issue to GTD task"},
    %{
      subject: "github.issue.link_project",
      type: :responder,
      description: "Link issue to GTD project"
    },
    %{subject: "github.issue.linked", type: :responder, description: "List linked issues"}
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Logger.info("[NATS.Consumer] Starting GitHub NATS consumer")

    state = %{
      subscriptions: [],
      conn: nil,
      opts: opts
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5000) do
      {:ok, conn} ->
        BotArmyRuntime.NATS.Connection.subscribe_to_status()
        Logger.info("[NATS.Consumer] Connected to NATS, subscribing to GitHub subjects")

        subscriptions =
          @subjects
          |> Enum.map(fn %{subject: subject} ->
            case Gnat.sub(conn, self(), subject) do
              {:ok, sub} ->
                Logger.info("[NATS.Consumer] Subscribed to #{subject}")
                sub

              {:error, reason} ->
                Logger.error(
                  "[NATS.Consumer] Failed to subscribe to #{subject}: #{inspect(reason)}"
                )

                nil
            end
          end)
          |> Enum.filter(&(not is_nil(&1)))

        BotArmyRuntime.Registry.register("github", @subjects, @version)

        {:noreply, %{state | subscriptions: subscriptions, conn: conn}}

      {:error, _reason} ->
        Logger.warning("[NATS.Consumer] NATS connection not ready, will retry")
        Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:connect_retry, state) do
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info({:msg, msg}, state) do
    BotArmyRuntime.Tracing.with_consumer_span(msg.topic, Map.get(msg, :headers), fn ->
      case BotArmyCore.NATS.Decoder.decode(msg.body) do
        {:ok, decoded_message} ->
          if msg.reply_to do
            # Request/reply pattern
            route_request(decoded_message, msg.topic, msg.reply_to, state)
          else
            # Pub/sub pattern
            route_message(decoded_message, msg.topic)
          end

        {:error, reason} ->
          Logger.warning(
            "[NATS.Consumer] Failed to decode message from #{msg.topic}: #{inspect(reason)}"
          )
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:nats, :disconnected}, state) do
    Logger.warning("[NATS.Consumer] Disconnected from NATS, will reconnect")
    Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
    {:noreply, %{state | subscriptions: [], conn: nil}}
  end

  @impl true
  def handle_info({:nats, :connected}, state) do
    Logger.info("[NATS.Consumer] Reconnected to NATS, re-subscribing")
    {:noreply, state, {:continue, :connect}}
  end

  defp route_message(payload, "github.pr." <> action) do
    handle_pr_event(payload, action)
  end

  defp route_message(payload, "github.issue." <> action) do
    handle_issue_event(payload, action)
  end

  defp route_message(payload, "github.ci." <> action) do
    handle_ci_event(payload, action)
  end

  defp route_message(_payload, topic) do
    Logger.debug("[NATS.Consumer] Unhandled topic: #{topic}")
  end

  # Request/reply handlers for GitHub queries and writes
  defp route_request(payload, "github.pr.get", reply_to, state) do
    case payload do
      %{"owner" => owner, "repo" => repo, "number" => number} ->
        case BotArmyGitHub.GitHub.Client.get_pr(owner, repo, number) do
          {:ok, data} ->
            send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.ok(%{data: data}))

          {:error, reason} ->
            send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.error(reason))
        end

      _ ->
        send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.error("missing parameters"))
    end
  end

  defp route_request(payload, "github.issue.list", reply_to, state) do
    case payload do
      %{"owner" => owner, "repo" => repo} ->
        state_param = Map.get(payload, "state", "open")

        case BotArmyGitHub.GitHub.Client.list_issues(owner, repo, state_param) do
          {:ok, issues} ->
            send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.ok(%{data: issues}))

          {:error, reason} ->
            send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.error(reason))
        end

      _ ->
        send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.error("missing parameters"))
    end
  end

  defp route_request(payload, "github.repo.file", reply_to, state) do
    case payload do
      %{"owner" => owner, "repo" => repo, "path" => path} ->
        case BotArmyGitHub.GitHub.Client.get_file(owner, repo, path) do
          {:ok, file} ->
            send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.ok(%{data: file}))

          {:error, reason} ->
            send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.error(reason))
        end

      _ ->
        send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.error("missing parameters"))
    end
  end

  defp route_request(payload, "github.ci.status", reply_to, state) do
    case payload do
      %{"owner" => owner, "repo" => repo, "ref" => ref} ->
        case BotArmyGitHub.GitHub.Client.get_ci_status(owner, repo, ref) do
          {:ok, status} ->
            send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.ok(%{data: status}))

          {:error, reason} ->
            send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.error(reason))
        end

      _ ->
        send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.error("missing parameters"))
    end
  end

  defp route_request(payload, "github.pr.comment", reply_to, state) do
    case payload do
      %{"owner" => owner, "repo" => repo, "number" => number, "body" => body} ->
        case BotArmyGitHub.GitHub.Client.create_pr_comment(owner, repo, number, body) do
          {:ok, comment} ->
            send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.ok(%{data: comment}))

          {:error, reason} ->
            send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.error(reason))
        end

      _ ->
        send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.error("missing parameters"))
    end
  end

  defp route_request(payload, "github.issue.create", reply_to, state) do
    case payload do
      %{"owner" => owner, "repo" => repo, "title" => title, "body" => body} ->
        case BotArmyGitHub.GitHub.Client.create_issue(owner, repo, title, body) do
          {:ok, issue} ->
            send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.ok(%{data: issue}))

          {:error, reason} ->
            send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.error(reason))
        end

      _ ->
        send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.error("missing parameters"))
    end
  end

  defp route_request(payload, "github.issue.close", reply_to, state) do
    case payload do
      %{"owner" => owner, "repo" => repo, "number" => number} ->
        case BotArmyGitHub.GitHub.Client.close_issue(owner, repo, number) do
          {:ok, issue} ->
            send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.ok(%{data: issue}))

          {:error, reason} ->
            send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.error(reason))
        end

      _ ->
        send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.error("missing parameters"))
    end
  end

  defp route_request(payload, "github.pr.approve", reply_to, state) do
    case payload do
      %{"owner" => owner, "repo" => repo, "number" => number} ->
        case BotArmyGitHub.GitHub.Client.approve_pr(owner, repo, number) do
          {:ok, approval} ->
            send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.ok(%{data: approval}))

          {:error, reason} ->
            send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.error(reason))
        end

      _ ->
        send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.error("missing parameters"))
    end
  end

  defp route_request(payload, "github.issue.sync", reply_to, state) do
    case payload do
      %{"owner" => owner, "repo" => repo} ->
        case BotArmyGithub.IssueSyncWorker.sync_repo_issues(owner, repo, nil) do
          {:ok, count} ->
            send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.ok(%{synced: count}))

          {:error, reason} ->
            send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.error(reason))
        end

      _ ->
        send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.error("missing parameters"))
    end
  end

  defp route_request(payload, "github.issue.link_task", reply_to, state) do
    case payload do
      %{
        "owner" => owner,
        "repo" => repo,
        "issue_number" => issue_number,
        "task_id" => task_id
      } ->
        case BotArmyGithub.IssueSyncWorker.link_issue_to_task(
               owner,
               repo,
               issue_number,
               task_id
             ) do
          {:ok, issue} ->
            send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.ok(%{data: issue}))

          {:error, reason} ->
            send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.error(reason))
        end

      _ ->
        send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.error("missing parameters"))
    end
  end

  defp route_request(payload, "github.issue.link_project", reply_to, state) do
    case payload do
      %{
        "owner" => owner,
        "repo" => repo,
        "issue_number" => issue_number,
        "project_id" => project_id
      } ->
        case BotArmyGithub.IssueSyncWorker.link_issue_to_project(
               owner,
               repo,
               issue_number,
               project_id
             ) do
          {:ok, issue} ->
            send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.ok(%{data: issue}))

          {:error, reason} ->
            send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.error(reason))
        end

      _ ->
        send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.error("missing parameters"))
    end
  end

  defp route_request(payload, "github.issue.linked", reply_to, state) do
    case payload do
      %{"owner" => owner, "repo" => repo} ->
        case BotArmyGithub.IssueSyncWorker.list_linked_issues(owner, repo) do
          {:ok, issues} ->
            send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.ok(%{data: issues}))

          {:error, reason} ->
            send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.error(reason))
        end

      _ ->
        send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.error("missing parameters"))
    end
  end

  defp route_request(_payload, topic, reply_to, state) do
    Logger.debug("[NATS.Consumer] Unhandled request topic: #{topic}")
    send_reply(state, reply_to, BotArmyRuntime.NATS.Reply.error("unknown_subject"))
  end

  defp send_reply(state, reply_to, response) do
    case state.conn do
      nil ->
        Logger.error("[NATS.Consumer] No connection available for reply")

      conn ->
        Gnat.pub(conn, reply_to, Jason.encode!(response))
    end
  end

  defp handle_pr_event(
         %{
           "repo" => repo,
           "number" => number,
           "title" => title,
           "url" => url,
           "action" => action
         },
         _action
       ) do
    priority = if action == "review_requested", do: "high", else: "normal"

    payload = %{
      "title" => "PR #{number}: #{title}",
      "description" => "Review needed at #{url}",
      "context" => "next",
      "priority" => priority,
      "source" => "github",
      "source_metadata" => %{
        "repo" => repo,
        "number" => number,
        "url" => url,
        "type" => "pull_request",
        "action" => action
      }
    }

    publish_to_gtd(payload)
  end

  defp handle_issue_event(
         %{
           "repo" => repo,
           "number" => number,
           "title" => title,
           "url" => url,
           "action" => action
         },
         _action
       ) do
    payload = %{
      "title" => "Issue #{number}: #{title}",
      "description" => "Opened at #{url}",
      "context" => "inbox",
      "priority" => "normal",
      "source" => "github",
      "source_metadata" => %{
        "repo" => repo,
        "number" => number,
        "url" => url,
        "type" => "issue",
        "action" => action
      }
    }

    publish_to_gtd(payload)
  end

  defp handle_ci_event(%{"repo" => repo, "workflow" => workflow, "status" => "failure"}, _action) do
    payload = %{
      "title" => "CI Failed: #{workflow}",
      "description" => "Workflow failed in #{repo}",
      "context" => "next",
      "priority" => "urgent",
      "source" => "github",
      "source_metadata" => %{
        "repo" => repo,
        "workflow" => workflow,
        "type" => "ci",
        "status" => "failure"
      }
    }

    publish_to_gtd(payload)
  end

  defp handle_ci_event(_payload, _action), do: :ok

  defp publish_to_gtd(payload) do
    case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 2_000) do
      {:ok, conn} ->
        Gnat.pub(conn, "gtd.inbox.add", Jason.encode!(payload))

        Logger.info("[NATS.Consumer] Published to gtd.inbox.add",
          title: Map.get(payload, "title")
        )

      {:error, reason} ->
        Logger.error("[NATS.Consumer] Failed to publish to GTD", reason: inspect(reason))
    end
  end
end
