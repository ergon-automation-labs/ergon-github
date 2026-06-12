defmodule BotArmyGithub.Repo.Migrations.CreateGitHubIssues do
  use Ecto.Migration

  def up do
    create table(:github_issues, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:owner, :string, null: false)
      add(:repo, :string, null: false)
      add(:issue_number, :integer, null: false)
      add(:title, :string)
      add(:state, :string, default: "open")
      add(:labels, {:array, :string}, default: [])
      add(:url, :string)
      add(:gtd_task_id, :uuid)
      add(:gtd_project_id, :uuid)
      add(:last_synced_at, :utc_datetime_usec)
      add(:sync_status, :string, default: "pending")

      timestamps()
    end

    create(index(:github_issues, [:owner, :repo]))
    create(index(:github_issues, [:state]))
    create(index(:github_issues, [:gtd_task_id]))
    create(index(:github_issues, [:gtd_project_id]))

    create(
      unique_index(:github_issues, [:owner, :repo, :issue_number],
        name: :github_issues_owner_repo_issue_number_index
      )
    )
  end

  def down do
    drop(table(:github_issues))
  end
end
