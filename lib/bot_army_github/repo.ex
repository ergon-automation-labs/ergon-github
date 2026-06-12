defmodule BotArmyGithub.Repo do
  use Ecto.Repo,
    otp_app: :bot_army_github,
    adapter: Ecto.Adapters.Postgres
end
