defmodule BotArmyGithub.IssueSyncWorker do
  @moduledoc """
  Polls configured GitHub repos for open issues and tracks them locally.

  Links issues to GTD tasks/projects so Bot Army can find and work on them.
  """

  use GenServer
  require Logger

  alias BotArmyGithub.Schemas.GitHubIssue
  alias BotArmyGithub.Repo
  import Ecto.Query

  @default_poll_interval_ms :timer.minutes(15)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    poll_interval = Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)
    repos = Keyword.get(opts, :repos, [])

    state = %{
      poll_interval_ms: poll_interval,
      repos: repos,
      timer: nil
    }

    if Application.get_env(:bot_army_github, :env, :dev) != :test do
      Process.send_after(self(), :sync_all, 5_000)
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:sync_all, state) do
    for {owner, repo} <- state.repos do
      case sync_repo_issues(owner, repo, state) do
        {:ok, count} ->
          Logger.info("[IssueSyncWorker] Synced #{count} issues for #{owner}/#{repo}")

        {:error, reason} ->
          Logger.error("[IssueSyncWorker] Failed to sync #{owner}/#{repo}: #{inspect(reason)}")
      end
    end

    timer = Process.send_after(self(), :sync_all, state.poll_interval_ms)
    {:noreply, %{state | timer: timer}}
  end

  @impl true
  def handle_info(:stop, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    {:stop, :normal, state}
  end

  def sync_repo_issues(owner, repo, _state) do
    case BotArmyGitHub.GitHub.Client.list_issues(owner, repo, "open") do
      {:ok, issues} ->
        count =
          Enum.reduce(issues, 0, fn issue_data, acc ->
            attrs = %{
              owner: owner,
              repo: repo,
              issue_number: issue_data.number,
              title: issue_data.title,
              state: issue_data.state,
              labels: issue_data.labels,
              url: issue_data.url,
              last_synced_at: DateTime.utc_now(),
              sync_status: "synced"
            }

            existing =
              Repo.one(
                from(i in GitHubIssue,
                  where:
                    i.owner == ^owner and i.repo == ^repo and
                      i.issue_number == ^issue_data.number
                )
              )

            changeset =
              if existing do
                GitHubIssue.changeset(existing, attrs)
              else
                GitHubIssue.changeset(%GitHubIssue{}, attrs)
              end

            case Repo.insert_or_update(changeset) do
              {:ok, _} -> acc + 1
              {:error, _} -> acc
            end
          end)

        {:ok, count}

      error ->
        error
    end
  end

  def link_issue_to_task(owner, repo, issue_number, task_id) do
    case find_issue(owner, repo, issue_number) do
      nil ->
        {:error, :not_found}

      issue ->
        changeset = GitHubIssue.changeset(issue, %{gtd_task_id: task_id})

        case Repo.update(changeset) do
          {:ok, updated} -> {:ok, updated}
          {:error, changeset} -> {:error, changeset.errors}
        end
    end
  end

  def link_issue_to_project(owner, repo, issue_number, project_id) do
    case find_issue(owner, repo, issue_number) do
      nil ->
        {:error, :not_found}

      issue ->
        changeset = GitHubIssue.changeset(issue, %{gtd_project_id: project_id})

        case Repo.update(changeset) do
          {:ok, updated} -> {:ok, updated}
          {:error, changeset} -> {:error, changeset.errors}
        end
    end
  end

  def get_issue_with_links(owner, repo, issue_number) do
    case find_issue(owner, repo, issue_number) do
      nil -> {:error, :not_found}
      issue -> {:ok, issue}
    end
  end

  def list_linked_issues(owner, repo) do
    issues =
      Repo.all(
        from(i in GitHubIssue,
          where: i.owner == ^owner and i.repo == ^repo and not is_nil(i.gtd_task_id),
          order_by: [desc: i.inserted_at]
        )
      )

    {:ok, issues}
  end

  defp find_issue(owner, repo, issue_number) do
    Repo.one(
      from(i in GitHubIssue,
        where: i.owner == ^owner and i.repo == ^repo and i.issue_number == ^issue_number
      )
    )
  end
end
