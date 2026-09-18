import Config

if config_env() != :test do
  alias BotArmyLibraryRuntime.Ecto.RuntimeDbConfig

  db_config =
    RuntimeDbConfig.resolve("BOT_ARMY_GITHUB", database: "ergon_github", port: 5432)

  config :bot_army_github,
         BotArmyGithub.Repo,
         Keyword.put(db_config, :pool_size, RuntimeDbConfig.pool_size("BOT_ARMY_GITHUB", 10))
end
