defmodule BotArmyGitHub.GitHub.Client do
  @moduledoc "GitHub API client for reading PR, issue, and CI data."

  require Logger

  @api_base "https://api.github.com"
  @timeout_ms 10_000

  def get_pr(owner, repo, number) do
    url = "#{@api_base}/repos/#{owner}/#{repo}/pulls/#{number}"
    headers = build_headers()

    case HTTPoison.get(url, headers, timeout: @timeout_ms) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, data} ->
            {:ok,
             %{
               number: data["number"],
               title: data["title"],
               state: data["state"],
               url: data["html_url"],
               draft: data["draft"],
               merged: data["merged"],
               ci_status: check_pr_ci_status(owner, repo, data["head"]["sha"]),
               changed_files: data["changed_files"],
               additions: data["additions"],
               deletions: data["deletions"]
             }}

          {:error, reason} ->
            {:error, {:decode_failed, reason}}
        end

      {:ok, %{status_code: 404}} ->
        {:error, :not_found}

      {:ok, %{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  def list_issues(owner, repo, state \\ "open") do
    url = "#{@api_base}/repos/#{owner}/#{repo}/issues?state=#{state}&per_page=50"
    headers = build_headers()

    case HTTPoison.get(url, headers, timeout: @timeout_ms) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, issues} when is_list(issues) ->
            issues_data =
              issues
              |> Enum.reject(fn i -> Map.get(i, "pull_request") end)
              |> Enum.map(fn issue ->
                %{
                  number: issue["number"],
                  title: issue["title"],
                  state: issue["state"],
                  url: issue["html_url"],
                  labels: Enum.map(issue["labels"], & &1["name"])
                }
              end)

            {:ok, issues_data}

          {:error, reason} ->
            {:error, {:decode_failed, reason}}
        end

      {:ok, %{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  def get_file(owner, repo, path) do
    url = "#{@api_base}/repos/#{owner}/#{repo}/contents/#{path}"
    headers = build_headers()

    case HTTPoison.get(url, headers, timeout: @timeout_ms) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, data} ->
            case Base.decode64(data["content"]) do
              {:ok, content} ->
                {:ok,
                 %{
                   path: data["path"],
                   name: data["name"],
                   size: data["size"],
                   content: content
                 }}

              :error ->
                {:error, :decode_failed}
            end

          {:error, reason} ->
            {:error, {:decode_failed, reason}}
        end

      {:ok, %{status_code: 404}} ->
        {:error, :not_found}

      {:ok, %{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  def get_ci_status(owner, repo, ref) do
    url = "#{@api_base}/repos/#{owner}/#{repo}/commits/#{ref}/status"
    headers = build_headers()

    case HTTPoison.get(url, headers, timeout: @timeout_ms) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, data} ->
            {:ok,
             %{
               state: data["state"],
               statuses:
                 Enum.map(data["statuses"], fn s ->
                   %{
                     context: s["context"],
                     state: s["state"],
                     description: s["description"]
                   }
                 end)
             }}

          {:error, reason} ->
            {:error, {:decode_failed, reason}}
        end

      {:ok, %{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  def create_pr_comment(owner, repo, issue_number, body) do
    url = "#{@api_base}/repos/#{owner}/#{repo}/issues/#{issue_number}/comments"
    headers = build_headers()
    payload = Jason.encode!(%{"body" => body})

    case HTTPoison.post(url, payload, headers, timeout: @timeout_ms) do
      {:ok, %{status_code: 201, body: body}} ->
        case Jason.decode(body) do
          {:ok, data} ->
            {:ok, %{id: data["id"], url: data["html_url"]}}

          {:error, reason} ->
            {:error, {:decode_failed, reason}}
        end

      {:ok, %{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  def create_issue(owner, repo, title, body) do
    url = "#{@api_base}/repos/#{owner}/#{repo}/issues"
    headers = build_headers()
    payload = Jason.encode!(%{"title" => title, "body" => body})

    case HTTPoison.post(url, payload, headers, timeout: @timeout_ms) do
      {:ok, %{status_code: 201, body: body}} ->
        case Jason.decode(body) do
          {:ok, data} ->
            {:ok, %{number: data["number"], url: data["html_url"]}}

          {:error, reason} ->
            {:error, {:decode_failed, reason}}
        end

      {:ok, %{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  def close_issue(owner, repo, issue_number) do
    url = "#{@api_base}/repos/#{owner}/#{repo}/issues/#{issue_number}"
    headers = build_headers()
    payload = Jason.encode!(%{"state" => "closed"})

    case HTTPoison.patch(url, payload, headers, timeout: @timeout_ms) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, data} ->
            {:ok, %{state: data["state"], url: data["html_url"]}}

          {:error, reason} ->
            {:error, {:decode_failed, reason}}
        end

      {:ok, %{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  def approve_pr(owner, repo, issue_number) do
    url = "#{@api_base}/repos/#{owner}/#{repo}/pulls/#{issue_number}/reviews"
    headers = build_headers()
    payload = Jason.encode!(%{"event" => "APPROVE"})

    case HTTPoison.post(url, payload, headers, timeout: @timeout_ms) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, data} ->
            {:ok, %{id: data["id"], state: data["state"]}}

          {:error, reason} ->
            {:error, {:decode_failed, reason}}
        end

      {:ok, %{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp check_pr_ci_status(owner, repo, sha) do
    case get_ci_status(owner, repo, sha) do
      {:ok, %{state: state}} -> state
      {:error, _} -> "unknown"
    end
  end

  defp build_headers do
    token = System.get_env("GITHUB_TOKEN")

    headers = [
      {"Accept", "application/vnd.github.v3+json"},
      {"User-Agent", "BotArmyGitHub"}
    ]

    if token && token != "" do
      [{"Authorization", "token #{token}"} | headers]
    else
      headers
    end
  end
end
