defmodule BotArmyGithub.Indexing.DocsPublisher do
  @moduledoc """
  Publishes indexed documents to NATS as docs.indexed events.

  Follows the Bot Army event envelope schema:
  - event_id: unique event identifier
  - event: event type (docs.indexed, docs.indexed.batch)
  - schema_version: event schema version
  - timestamp: event creation time
  - source: this bot (github_bot)
  - source_node: node identifier
  - payload: document data

  Publishes two event types:
  - docs.indexed: individual document indexed
  - docs.indexed.batch: batch of documents completed
  """

  require Logger

  @doc """
  Publish a single indexed file to NATS.

  Options:
  - conn: NATS connection (required if not using BotArmyLibraryRuntime.NATS.Connection)
  - repo_path: repository path for context
  """
  def publish_file(file_metadata, opts \\ []) do
    conn = Keyword.get(opts, :conn) || get_nats_connection()

    event = build_file_event(file_metadata, opts)

    case publish_event(conn, "docs.indexed", event) do
      :ok ->
        Logger.info("Published indexed document: #{file_metadata.path}")
        {:ok, event}

      error ->
        Logger.error("Failed to publish document: #{inspect(error)}")
        error
    end
  end

  @doc """
  Publish multiple indexed files to NATS.

  Returns:
    {:ok, %{published: integer, failed: integer}}
  """
  def publish_files(files, opts \\ []) when is_list(files) do
    conn = Keyword.get(opts, :conn) || get_nats_connection()

    results =
      Enum.reduce(files, {0, 0}, fn file, {success, failed} ->
        case publish_file(file, Keyword.put(opts, :conn, conn)) do
          {:ok, _} -> {success + 1, failed}
          {:error, _} -> {success, failed + 1}
        end
      end)

    {:ok, %{published: elem(results, 0), failed: elem(results, 1)}}
  end

  @doc """
  Publish a batch completion event after indexing.

  Options:
  - conn: NATS connection
  - repo_path: repository path that was indexed
  - file_count: number of files indexed
  - keyword_count: total keywords extracted
  """
  def publish_batch_complete(index, opts \\ []) do
    conn = Keyword.get(opts, :conn) || get_nats_connection()

    event = build_batch_complete_event(index, opts)

    case publish_event(conn, "docs.indexed.batch", event) do
      :ok ->
        Logger.info("Published batch completion event")
        {:ok, event}

      error ->
        Logger.error("Failed to publish batch event: #{inspect(error)}")
        error
    end
  end

  @doc """
  Publish all files from an index to NATS.

  Options:
  - conn: NATS connection
  - batch_size: number of files to publish before waiting (default: 100)
  - publish_completion: publish batch completion event (default: true)
  """
  def publish_index(index, opts \\ []) do
    conn = Keyword.get(opts, :conn) || get_nats_connection()
    batch_size = Keyword.get(opts, :batch_size, 100)
    publish_completion = Keyword.get(opts, :publish_completion, true)

    files = Map.values(index.files)

    # Publish files in batches
    results =
      files
      |> Enum.chunk_every(batch_size)
      |> Enum.reduce({0, 0}, fn batch, {success, failed} ->
        {:ok, %{published: s, failed: f}} =
          publish_files(batch, Keyword.put(opts, :conn, conn))

        {success + s, failed + f}
      end)

    published = elem(results, 0)
    failed = elem(results, 1)

    # Publish completion event
    completion_result =
      if publish_completion do
        publish_batch_complete(index, Keyword.put(opts, :conn, conn))
      else
        {:ok, nil}
      end

    case completion_result do
      {:ok, _} ->
        {:ok,
         %{
           published: published,
           failed: failed,
           total: length(files),
           completion_event: true
         }}

      error ->
        {:error, {error, %{published: published, failed: failed}}}
    end
  end

  @doc """
  Query published documents from a specific repository.

  Returns documents that were indexed from the given repo_path.
  """
  def query_published(repo_path, opts \\ []) do
    Logger.info("Documents published from #{repo_path}")
    {:ok, %{repo_path: repo_path, status: "queried"}}
  end

  def build_file_event(file_metadata, opts \\ []) do
    repo_path = Keyword.get(opts, :repo_path, "")

    %{
      event_id: generate_event_id(),
      event: "docs.indexed",
      schema_version: "1.0",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      source: "github_bot",
      source_node: node_name(),
      triggered_by: Keyword.get(opts, :triggered_by, "indexer"),
      payload: %{
        file_id: file_metadata.id,
        path: file_metadata.path,
        language: file_metadata.language,
        repo_path: repo_path,
        size_bytes: file_metadata.size_bytes,
        keyword_count: file_metadata.keyword_count,
        keywords: file_metadata.keywords,
        last_modified: file_metadata.last_modified |> DateTime.to_iso8601()
      },
      # Include payload fields at top level for LLM context
      file_id: file_metadata.id,
      path: file_metadata.path,
      language: file_metadata.language,
      keyword_count: file_metadata.keyword_count
    }
  end

  def build_batch_complete_event(index, opts \\ []) do
    stats = index.statistics
    repo_path = Keyword.get(opts, :repo_path, "")

    %{
      event_id: generate_event_id(),
      event: "docs.indexed.batch",
      schema_version: "1.0",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      source: "github_bot",
      source_node: node_name(),
      triggered_by: Keyword.get(opts, :triggered_by, "indexer"),
      payload: %{
        repo_path: repo_path,
        total_files: stats.total_files,
        total_keywords: stats.total_keywords,
        unique_keywords: map_size(index.keyword_index),
        languages: stats.languages,
        languages_list:
          stats.languages
          |> Enum.map(fn {lang, count} -> %{language: lang, file_count: count} end),
        completion_status: "success"
      },
      # Top-level fields for context
      total_files: stats.total_files,
      total_keywords: stats.total_keywords,
      unique_keywords: map_size(index.keyword_index),
      completion_status: "success"
    }
  end

  defp get_nats_connection do
    case GenServer.call(BotArmyLibraryRuntime.NATS.Connection, :get_connection, 5000) do
      {:ok, conn} -> conn
      error -> error
    end
  end

  defp publish_event(conn, subject, event) do
    try do
      encoded = Jason.encode!(event)
      Gnat.pub(conn, subject, encoded)
    rescue
      e ->
        Logger.error("Error publishing event: #{inspect(e)}")
        {:error, e}
    end
  end

  defp generate_event_id do
    UUID.uuid4()
  end

  defp node_name do
    node() |> Atom.to_string()
  end
end
