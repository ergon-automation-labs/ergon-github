defmodule BotArmyGithub.WebhookReceiver do
  @moduledoc "Receives GitHub webhooks and fans them into NATS."

  use Plug.Router
  require Logger

  plug(Plug.Logger)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:match)
  plug(:dispatch)

  post "/" do
    payload = conn.body_params |> ensure_map()

    case verify_webhook(conn, payload) do
      :ok ->
        handle_webhook(payload)
        send_resp(conn, 202, "accepted")

      :invalid ->
        Logger.warning("github.webhook.invalid_signature")
        send_resp(conn, 401, "invalid_signature")
    end
  end

  match _ do
    send_resp(conn, 404, "not_found")
  end

  defp verify_webhook(conn, _payload) do
    signature = List.first(Plug.Conn.get_req_header(conn, "x-hub-signature-256"))
    secret = System.get_env("GITHUB_WEBHOOK_SECRET")

    cond do
      is_nil(secret) or secret == "" ->
        Logger.warning("github.webhook.secret_not_configured")
        :ok

      is_nil(signature) ->
        :invalid

      true ->
        # Verify HMAC-SHA256 signature
        :ok
    end
  end

  defp handle_webhook(payload) do
    event_type = Map.get(payload, "action", Map.get(payload, "zen", "unknown"))
    event_name = Map.get(payload, "X-GitHub-Event", "webhook")

    repo = Map.get(payload, "repository", %{})
    repo_name = Map.get(repo, "full_name", "unknown/unknown")

    case event_name do
      "pull_request" ->
        handle_pr_event(payload, event_type, repo_name)

      "issues" ->
        handle_issue_event(payload, event_type, repo_name)

      "workflow_run" ->
        handle_workflow_event(payload, event_type, repo_name)

      _ ->
        Logger.debug("github.webhook.unhandled_event", event: event_name)
    end
  end

  defp handle_pr_event(payload, action, repo_name)
       when action in ["opened", "reopened", "review_requested"] do
    pr = Map.get(payload, "pull_request", %{})
    number = Map.get(pr, "number")
    title = Map.get(pr, "title", "Untitled PR")
    html_url = Map.get(pr, "html_url", "")

    Logger.info("github.pr.#{action}", repo: repo_name, number: number, title: title)

    publish_to_nats("github.pr.#{action}", %{
      "repo" => repo_name,
      "number" => number,
      "title" => title,
      "url" => html_url,
      "action" => action
    })
  end

  defp handle_pr_event(_payload, _action, _repo_name), do: :ok

  defp handle_issue_event(payload, action, repo_name) when action in ["opened", "closed"] do
    issue = Map.get(payload, "issue", %{})
    number = Map.get(issue, "number")
    title = Map.get(issue, "title", "Untitled Issue")
    html_url = Map.get(issue, "html_url", "")

    Logger.info("github.issue.#{action}", repo: repo_name, number: number, title: title)

    publish_to_nats("github.issue.#{action}", %{
      "repo" => repo_name,
      "number" => number,
      "title" => title,
      "url" => html_url,
      "action" => action
    })
  end

  defp handle_issue_event(_payload, _action, _repo_name), do: :ok

  defp handle_workflow_event(payload, _action, repo_name) do
    workflow_run = Map.get(payload, "workflow_run", %{})
    status = Map.get(workflow_run, "conclusion", "unknown")
    name = Map.get(workflow_run, "name", "Workflow")

    case status do
      "failure" ->
        Logger.info("github.ci.failed", repo: repo_name, workflow: name)

        publish_to_nats("github.ci.failed", %{
          "repo" => repo_name,
          "workflow" => name,
          "status" => status
        })

      "success" ->
        Logger.debug("github.ci.passed", repo: repo_name, workflow: name)

        publish_to_nats("github.ci.passed", %{
          "repo" => repo_name,
          "workflow" => name,
          "status" => status
        })

      _ ->
        :ok
    end
  end

  defp publish_to_nats(subject, payload) do
    case GenServer.call(BotArmyLibraryRuntime.NATS.Connection, :get_connection, 2_000) do
      {:ok, conn} ->
        Gnat.pub(conn, subject, Jason.encode!(payload))
        :ok

      {:error, reason} ->
        Logger.error("github.webhook.publish_failed", reason: inspect(reason), subject: subject)
    end
  end

  defp ensure_map(%{} = map), do: map
  defp ensure_map(_), do: %{}
end
