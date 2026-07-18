defmodule BotArmyGithub.NATS.DocsSearchResponder do
  @moduledoc """
  NATS responder for GitHub ingestor search and stats queries.

  Subjects:
  - github.docs.search: Search indexed documents
  - github.docs.stats: Get indexing statistics
  """

  require Logger

  alias BotArmyGithub.Indexing.IndexBuilder

  @doc """
  Start the responder and subscribe to search queries.

  This handler maintains an in-memory index and responds to search requests.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    repo_path = Keyword.get(opts, :repo_path, "/Users/abby/code")

    case IndexBuilder.build_from_repo(repo_path) do
      {:ok, index} ->
        Logger.info("[DocsSearchResponder] Index built from #{repo_path}")

        conn = GenServer.call(BotArmyLibraryRuntime.NATS.Connection, :get_connection, 5000)

        with {:ok, _} <- Gnat.sub(conn, self(), "github.docs.search"),
             {:ok, _} <- Gnat.sub(conn, self(), "github.docs.stats") do
          Logger.info("[DocsSearchResponder] Subscribed to search and stats queries")
          {:ok, %{index: index, conn: conn}}
        else
          error ->
            Logger.error("[DocsSearchResponder] Failed to subscribe: #{inspect(error)}")
            {:error, error}
        end

      error ->
        Logger.error("[DocsSearchResponder] Failed to build index: #{inspect(error)}")
        {:error, error}
    end
  end

  def handle_info({:msg, msg}, state) do
    case msg.topic do
      "github.docs.search" ->
        handle_search(msg, state)

      "github.docs.stats" ->
        handle_stats(msg, state)

      _ ->
        Logger.warning("[DocsSearchResponder] Unknown topic: #{msg.topic}")
    end

    {:noreply, state}
  end

  # Private

  defp handle_search(msg, state) do
    try do
      req = Jason.decode!(msg.body)

      query = Map.get(req, "query", "")

      language =
        case Map.get(req, "language") do
          "" -> nil
          nil -> nil
          lang -> String.to_atom(lang)
        end

      limit = Map.get(req, "limit", 50)

      opts = [limit: limit]
      opts = if language, do: Keyword.put(opts, :language, language), else: opts

      {:ok, result} = IndexBuilder.search(state.index, query, opts)

      response = %{
        results: result.results,
        count: result.count,
        query: result.query
      }

      reply_json(msg.reply_to, response, state.conn)
    rescue
      e ->
        Logger.error("[DocsSearchResponder] Error handling search: #{inspect(e)}")

        error_response = %{
          error: "Search failed",
          message: inspect(e)
        }

        reply_json(msg.reply_to, error_response, state.conn)
    end
  end

  defp handle_stats(msg, state) do
    try do
      stats = IndexBuilder.statistics(state.index)

      response = %{
        total_files: stats.total_files,
        total_keywords: stats.total_keywords,
        languages: stats.languages
      }

      reply_json(msg.reply_to, response, state.conn)
    rescue
      e ->
        Logger.error("[DocsSearchResponder] Error handling stats: #{inspect(e)}")

        error_response = %{
          error: "Stats query failed",
          message: inspect(e)
        }

        reply_json(msg.reply_to, error_response, state.conn)
    end
  end

  defp reply_json(reply_to, data, conn) do
    {:ok, json} = Jason.encode(data)
    Gnat.pub(conn, reply_to, json)
  end
end
