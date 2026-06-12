defmodule GithubBot.Release do
  @moduledoc """
  Release tasks for github_bot OTP release.

  Run migrations via: ./bin/github_bot eval "GithubBot.Release.migrate()"
  """

  @app :bot_army_github

  def migrate do
    BotArmyRuntime.Ecto.MigrationRunner.run(
      repo_module: BotArmyGithub.Repo,
      app_module: @app
    )
  end
end
