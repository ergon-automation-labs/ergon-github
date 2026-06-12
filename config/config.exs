import Config

config :bot_army_github,
  ecto_repos: [BotArmyGithub.Repo],
  default_tenant_id: "default"

config :bot_army_github, BotArmyGithub.Repo,
  database: System.get_env("BOT_ARMY_GITHUB_DB", "ergon_github"),
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  port: System.get_env("POSTGRES_PORT", "5432") |> String.to_integer(),
  pool_size: System.get_env("DB_POOL_SIZE", "10") |> String.to_integer()

config :logger, :console,
  format: "$time [$level] $metadata$message\n",
  metadata: [:request_id, :repo, :number, :title, :workflow, :reason, :subject, :event, :error]
