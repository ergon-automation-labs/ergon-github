defmodule BotArmyGithub.Indexing.IndexBuilder do
  @moduledoc """
  Builds an in-memory searchable index from files and keywords.

  Creates an inverted index structure for efficient keyword lookups:
  - keyword -> [file_ids]
  - file_id -> file_metadata + keywords
  - language -> [file_ids]

  Supports:
  - Full-text keyword search
  - File-based search
  - Language-filtered search
  - Ranking by relevance (frequency, position)
  """

  require Logger

  alias BotArmyGithub.Indexing.FilesystemWalker
  alias BotArmyGithub.Indexing.KeywordExtractor

  @doc """
  Build an index from a repository directory.

  Returns:
    {:ok, %Index{}} with:
    - keyword_index: map of keyword -> [file_ids]
    - files: map of file_id -> file_metadata
    - languages: map of language -> [file_ids]
    - statistics: index statistics
  """
  def build_from_repo(repo_path, opts \\ []) do
    with {:ok, files} <- FilesystemWalker.walk(repo_path, opts) do
      index = new_index()

      indexed =
        files
        |> Stream.filter(& &1.is_text)
        |> Enum.reduce(index, fn file, acc ->
          add_file_to_index(acc, file, repo_path)
        end)

      {:ok, indexed}
    else
      error -> error
    end
  end

  @doc """
  Create an empty index.
  """
  def new_index do
    %{
      keyword_index: %{},
      files: %{},
      languages: %{},
      statistics: %{
        total_files: 0,
        total_keywords: 0,
        languages: %{}
      }
    }
  end

  @doc """
  Add a single file to the index.
  """
  def add_file_to_index(index, file, repo_path) do
    file_id = generate_file_id(file.path)
    full_path = Path.join(repo_path, file.path)

    case KeywordExtractor.extract_keywords(File.read!(full_path), file.language) do
      {:ok, result} ->
        # Add file metadata
        file_metadata = %{
          id: file_id,
          path: file.path,
          language: file.language,
          size_bytes: file.size_bytes,
          keywords: result.keywords,
          keyword_count: result.count,
          last_modified: file.last_modified
        }

        index
        |> update_files_map(file_metadata)
        |> update_keyword_index(file_id, result.keywords)
        |> update_language_index(file_id, file.language)
        |> update_statistics(file_metadata)

      {:error, _reason} ->
        Logger.warning("Failed to extract keywords from #{file.path}")
        index
    end
  rescue
    e ->
      Logger.error("Error indexing file #{file.path}: #{inspect(e)}")
      index
  end

  @doc """
  Search the index for files matching keywords.

  Options:
  - language: filter by programming language
  - limit: maximum number of results (default: 50)
  - min_matches: minimum keyword matches required (default: 1)
  """
  def search(index, query, opts \\ []) when is_binary(query) do
    language = Keyword.get(opts, :language)
    limit = Keyword.get(opts, :limit, 50)
    min_matches = Keyword.get(opts, :min_matches, 1)

    query_keywords = String.split(query, ~r/\s+/, trim: true) |> Enum.map(&String.downcase/1)

    results =
      index.keyword_index
      |> Enum.flat_map(fn {keyword, file_ids} ->
        if Enum.any?(query_keywords, &String.contains?(keyword, &1)) do
          Enum.map(file_ids, &{&1, keyword})
        else
          []
        end
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {file_id, matched_keywords} ->
        {file_id, length(matched_keywords), matched_keywords}
      end)
      |> Enum.filter(&(elem(&1, 1) >= min_matches))
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.take(limit)
      |> Enum.map(fn {file_id, match_count, matched_keywords} ->
        file = index.files[file_id]

        %{
          file_id: file_id,
          path: file.path,
          language: file.language,
          match_count: match_count,
          matched_keywords: matched_keywords,
          score: calculate_score(match_count, file.keyword_count)
        }
      end)

    # Filter by language if specified
    results =
      if language do
        Enum.filter(results, &(&1.language == language))
      else
        results
      end

    {:ok,
     %{
       results: results,
       count: length(results),
       query: query,
       query_keywords: query_keywords
     }}
  end

  @doc """
  Search for files by exact path or pattern.
  """
  def search_files(index, path_pattern, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    results =
      index.files
      |> Map.values()
      |> Enum.filter(fn file ->
        String.contains?(String.downcase(file.path), String.downcase(path_pattern))
      end)
      |> Enum.sort_by(& &1.path)
      |> Enum.take(limit)

    {:ok,
     %{
       results: results,
       count: length(results),
       pattern: path_pattern
     }}
  end

  @doc """
  Get files by language.
  """
  def get_files_by_language(index, language, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    file_ids = Map.get(index.languages, language, []) |> Enum.take(limit)
    results = Enum.map(file_ids, &index.files[&1])

    {:ok,
     %{
       results: results,
       count: length(results),
       language: language
     }}
  end

  @doc """
  Get index statistics.
  """
  def statistics(index) do
    index.statistics
  end

  @doc """
  Get file metadata by ID.
  """
  def get_file(index, file_id) do
    case Map.fetch(index.files, file_id) do
      {:ok, file} -> {:ok, file}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  List all indexed files.
  """
  def list_files(index, opts \\ []) do
    limit = Keyword.get(opts, :limit, 1000)
    offset = Keyword.get(opts, :offset, 0)

    files =
      index.files
      |> Map.values()
      |> Enum.sort_by(& &1.path)
      |> Enum.drop(offset)
      |> Enum.take(limit)

    {:ok,
     %{
       files: files,
       count: length(files),
       total: map_size(index.files),
       offset: offset,
       limit: limit
     }}
  end

  @doc """
  Get all keywords in the index.
  """
  def list_keywords(index, opts \\ []) do
    limit = Keyword.get(opts, :limit, 1000)

    keywords =
      index.keyword_index
      |> Enum.map(fn {keyword, file_ids} ->
        %{
          keyword: keyword,
          file_count: length(file_ids),
          frequency: length(file_ids)
        }
      end)
      |> Enum.sort_by(& &1.frequency, :desc)
      |> Enum.take(limit)

    {:ok,
     %{
       keywords: keywords,
       count: length(keywords),
       total: map_size(index.keyword_index)
     }}
  end

  # Private

  defp update_files_map(index, file_metadata) do
    Map.update!(index, :files, &Map.put(&1, file_metadata.id, file_metadata))
  end

  defp update_keyword_index(index, file_id, keywords) do
    Map.update!(index, :keyword_index, fn keyword_index ->
      Enum.reduce(keywords, keyword_index, fn keyword, acc ->
        Map.update(acc, keyword, [file_id], &[file_id | &1])
      end)
    end)
  end

  defp update_language_index(index, file_id, language) do
    Map.update!(index, :languages, fn lang_index ->
      Map.update(lang_index, language, [file_id], &[file_id | &1])
    end)
  end

  defp update_statistics(index, file_metadata) do
    Map.update!(index, :statistics, fn stats ->
      %{
        stats
        | total_files: stats.total_files + 1,
          total_keywords: stats.total_keywords + file_metadata.keyword_count,
          languages:
            Map.update(
              stats.languages,
              file_metadata.language,
              1,
              &(&1 + 1)
            )
      }
    end)
  end

  defp generate_file_id(path) do
    :erlang.phash2(path)
  end

  defp calculate_score(match_count, total_keywords) do
    if total_keywords > 0 do
      min(match_count / total_keywords * 100, 100.0)
    else
      0.0
    end
  end
end
