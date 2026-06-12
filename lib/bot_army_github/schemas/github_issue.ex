defmodule BotArmyGithub.Schemas.GitHubIssue do
  @moduledoc """
  Tracks GitHub issues with their associated GTD task/project linkage.

  Allows Bot Army to find and work on issues by their GTD task identity.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "github_issues" do
    field(:repo, :string)
    field(:owner, :string)
    field(:issue_number, :integer)
    field(:title, :string)
    field(:state, :string, default: "open")
    field(:labels, {:array, :string}, default: [])
    field(:url, :string)
    field(:gtd_task_id, Ecto.UUID)
    field(:gtd_project_id, Ecto.UUID)
    field(:last_synced_at, :utc_datetime_usec)
    field(:sync_status, :string, default: "pending")

    timestamps()
  end

  def changeset(issue, attrs) do
    issue
    |> cast(attrs, [
      :repo,
      :owner,
      :issue_number,
      :title,
      :state,
      :labels,
      :url,
      :gtd_task_id,
      :gtd_project_id,
      :last_synced_at,
      :sync_status
    ])
    |> validate_required([:repo, :owner, :issue_number])
    |> unique_constraint([:owner, :repo, :issue_number],
      name: :github_issues_owner_repo_issue_number_index
    )
  end
end
