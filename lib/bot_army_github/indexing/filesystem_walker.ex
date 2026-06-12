defmodule BotArmyGithub.Indexing.FilesystemWalker do
  @moduledoc """
  Walks a GitHub repository filesystem, detecting file types and languages.

  Handles:
  - Recursive directory traversal
  - File type/language detection by extension
  - .gitignore pattern matching
  - Binary file filtering
  """

  require Logger

  @doc """
  Walk a local repository path, returning a list of indexed files with language detection.

  Returns:
    {:ok, [file_entry]}
    {:error, reason}

  File entry structure:
    %{
      path: string,
      language: atom,
      size_bytes: integer,
      last_modified: DateTime,
      is_text: boolean,
      gitignored: boolean
    }
  """
  def walk(repo_path, opts \\ []) do
    with :ok <- validate_path(repo_path),
         gitignore_patterns <- load_gitignore(repo_path),
         {:ok, files} <- traverse_directory(repo_path, gitignore_patterns, opts) do
      {:ok, files}
    else
      error -> error
    end
  end

  @doc """
  Detect the programming language of a file by extension.

  Returns an atom representing the language or :unknown
  """
  def detect_language(filepath) do
    filepath
    |> Path.extname()
    |> String.downcase()
    |> language_from_extension()
  end

  @doc """
  Check if a file is likely a text file (indexable) by extension.
  """
  def is_text_file?(filepath) do
    ext = filepath |> Path.extname() |> String.downcase()
    text_extensions() |> Enum.member?(ext)
  end

  # Private

  defp validate_path(path) do
    if File.exists?(path) and File.dir?(path) do
      :ok
    else
      {:error, {:invalid_path, path}}
    end
  end

  defp load_gitignore(repo_path) do
    gitignore_file = Path.join(repo_path, ".gitignore")

    if File.exists?(gitignore_file) do
      gitignore_file
      |> File.read!()
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    else
      []
    end
  end

  defp traverse_directory(root_path, gitignore_patterns, opts) do
    max_depth = Keyword.get(opts, :max_depth, 10)
    include_hidden = Keyword.get(opts, :include_hidden, false)

    try do
      files =
        collect_files_recursive(
          root_path,
          root_path,
          gitignore_patterns,
          max_depth,
          include_hidden
        )

      {:ok, files}
    rescue
      e ->
        Logger.error("Error traversing directory: #{inspect(e)}")
        {:error, {:traverse_failed, e}}
    end
  end

  defp collect_files_recursive(
         current_path,
         root_path,
         gitignore_patterns,
         max_depth,
         include_hidden
       ) do
    relative_path = Path.relative_to(current_path, root_path)
    depth = String.split(relative_path, "/") |> Enum.reject(&(&1 == "")) |> length()

    cond do
      depth > max_depth ->
        []

      File.dir?(current_path) ->
        current_path
        |> File.ls!()
        |> Enum.filter(fn entry ->
          include_hidden or not String.starts_with?(entry, ".")
        end)
        |> Enum.flat_map(fn entry ->
          full_path = Path.join(current_path, entry)

          collect_files_recursive(
            full_path,
            root_path,
            gitignore_patterns,
            max_depth,
            include_hidden
          )
        end)

      is_gitignored?(relative_path, gitignore_patterns) ->
        []

      is_binary_file?(current_path) ->
        []

      true ->
        [file_entry(current_path, root_path)]
    end
  rescue
    _ -> []
  end

  defp file_entry(full_path, root_path) do
    relative_path = Path.relative_to(full_path, root_path)
    {:ok, stat} = File.stat(full_path)

    # Convert Erlang datetime tuple {{year, month, day}, {hour, minute, second}} to DateTime
    {{year, month, day}, {hour, minute, second}} = stat.mtime

    {:ok, last_modified} =
      DateTime.new(Date.new!(year, month, day), Time.new!(hour, minute, second))

    %{
      path: relative_path,
      language: detect_language(full_path),
      size_bytes: stat.size,
      last_modified: last_modified,
      is_text: is_text_file?(full_path),
      gitignored: false
    }
  end

  defp is_gitignored?(relative_path, patterns) do
    Enum.any?(patterns, fn pattern ->
      path_matches_pattern?(relative_path, pattern)
    end)
  end

  defp path_matches_pattern?(path, pattern) do
    # Simple pattern matching: support *, **, .gitignore semantics
    cond do
      pattern == path ->
        true

      String.ends_with?(pattern, "/") ->
        # Directory pattern: "temp/" matches "temp/" and "temp/file.ex"
        dir_prefix = pattern
        path == dir_prefix or String.starts_with?(path, dir_prefix)

      String.ends_with?(pattern, "/*") ->
        String.starts_with?(path, String.trim_trailing(pattern, "/*"))

      String.ends_with?(pattern, "/**") ->
        String.starts_with?(path, String.trim_trailing(pattern, "/**"))

      String.contains?(pattern, "*") ->
        Regex.match?(glob_to_regex(pattern), path)

      true ->
        false
    end
  end

  defp glob_to_regex(glob) do
    glob
    |> String.replace(~r/\./, "\\.")
    |> String.replace(~r/\*\*/, ".*")
    |> String.replace(~r/\*/, "[^/]*")
    |> then(&Regex.compile!("^" <> &1 <> "$"))
  end

  defp is_binary_file?(path) do
    binary_extensions()
    |> Enum.any?(&String.ends_with?(String.downcase(path), &1))
  end

  defp language_from_extension(ext) do
    Map.get(extension_map(), ext, :unknown)
  end

  defp text_extensions do
    [
      # Source code
      ".ex",
      ".exs",
      ".erl",
      ".hrl",
      ".py",
      ".js",
      ".ts",
      ".jsx",
      ".tsx",
      ".go",
      ".rs",
      ".c",
      ".h",
      ".cpp",
      ".cc",
      ".java",
      ".kt",
      ".scala",
      ".rb",
      ".php",
      ".swift",
      # Markup
      ".html",
      ".xml",
      ".md",
      ".markdown",
      ".rst",
      ".asciidoc",
      # Data/Config
      ".json",
      ".yaml",
      ".yml",
      ".toml",
      ".ini",
      ".conf",
      ".config",
      ".env",
      # Text
      ".txt",
      ".sh",
      ".bash",
      ".zsh",
      ".sql",
      ".dockerfile",
      # Docs
      ".pdf",
      ".doc",
      ".docx"
    ]
  end

  defp binary_extensions do
    [
      ".png",
      ".jpg",
      ".jpeg",
      ".gif",
      ".webp",
      ".ico",
      ".svg",
      ".zip",
      ".tar",
      ".gz",
      ".rar",
      ".7z",
      ".exe",
      ".dll",
      ".so",
      ".dylib",
      ".bin",
      ".o",
      ".a",
      ".class",
      ".jar",
      ".pyc",
      ".beam",
      ".wasm"
    ]
  end

  defp extension_map do
    %{
      # Elixir
      ".ex" => :elixir,
      ".exs" => :elixir,
      # Erlang
      ".erl" => :erlang,
      ".hrl" => :erlang,
      # Python
      ".py" => :python,
      # JavaScript/TypeScript
      ".js" => :javascript,
      ".ts" => :typescript,
      ".jsx" => :javascript,
      ".tsx" => :typescript,
      # Go
      ".go" => :go,
      # Rust
      ".rs" => :rust,
      # C/C++
      ".c" => :c,
      ".h" => :c,
      ".cpp" => :cpp,
      ".cc" => :cpp,
      # Java
      ".java" => :java,
      ".kt" => :kotlin,
      # Other languages
      ".rb" => :ruby,
      ".php" => :php,
      ".swift" => :swift,
      ".scala" => :scala,
      # Markup
      ".md" => :markdown,
      ".html" => :html,
      ".xml" => :xml,
      ".rst" => :rst,
      # Data
      ".json" => :json,
      ".yaml" => :yaml,
      ".yml" => :yaml,
      ".toml" => :toml,
      # Shell
      ".sh" => :bash,
      ".bash" => :bash,
      ".sql" => :sql,
      # Dockerfile
      "dockerfile" => :dockerfile,
      ".dockerfile" => :dockerfile
    }
  end
end
