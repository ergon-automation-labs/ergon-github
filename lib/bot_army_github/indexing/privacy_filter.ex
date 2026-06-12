defmodule BotArmyGithub.Indexing.PrivacyFilter do
  @moduledoc """
  Privacy-aware filtering for GitHub ingestor.

  Prevents indexing of:
  - Sensitive files (secrets, credentials, private keys)
  - Common private directories (node_modules, venv, .git, etc.)
  - Gitignored files
  - Files with suspicious content patterns

  Configuration:
  - Sensitive file extensions (automatically filtered)
  - Private directories (automatically filtered)
  - Custom patterns via environment or config
  """

  require Logger

  @doc """
  Check if a file should be indexed based on privacy rules.

  Returns:
    {:ok, :allowed} - File can be indexed
    {:skip, reason} - File should be skipped (with reason)
  """
  def check_file(filepath, opts \\ []) do
    cond do
      # Check credentials first (most sensitive)
      is_credentials_file?(filepath) ->
        {:skip, :credentials_file}

      is_secrets_by_content?(filepath, Keyword.get(opts, :check_content, false)) ->
        {:skip, :contains_secrets}

      # Then sensitive file types
      is_sensitive_file?(filepath) ->
        {:skip, :sensitive_file}

      # Then gitignore patterns
      is_excluded_by_gitignore?(filepath, Keyword.get(opts, :gitignore_patterns, [])) ->
        {:skip, :gitignored}

      # Finally private directories
      is_private_directory?(filepath) ->
        {:skip, :private_directory}

      true ->
        {:ok, :allowed}
    end
  end

  @doc """
  Get privacy configuration for the indexer.

  Returns configuration that can be passed to FilesystemWalker and other modules.
  """
  def get_config do
    %{
      private_directories: private_directories(),
      sensitive_extensions: sensitive_extensions(),
      credentials_patterns: credentials_patterns(),
      check_content: System.get_env("GITHUB_INGESTOR_CHECK_SECRETS", "false") == "true"
    }
  end

  @doc """
  List all private directories that should be skipped.
  """
  def private_directories do
    [
      # Version control
      ".git",
      ".svn",
      ".hg",
      ".bzr",

      # Package managers
      "node_modules",
      "vendor",
      "venv",
      ".venv",
      "env",
      ".env",
      "__pycache__",
      ".gem",
      "gems",
      "go/pkg",
      ".cargo",
      "target",
      ".gradle",
      ".maven",

      # Build outputs
      "build",
      "dist",
      "out",
      ".next",
      ".nuxt",
      ".cache",
      ".parcel-cache",
      "coverage",
      ".coverage",
      ".nyc_output",

      # IDE/Editor
      ".vscode",
      ".idea",
      ".sublime",
      ".atom",
      ".emacs.d",
      ".vim",
      ".neovim",
      ".swp",
      ".swo",

      # OS
      ".DS_Store",
      "Thumbs.db",
      ".AppleDouble",
      ".LSOverride",

      # Logs
      "logs",
      "*.log",
      ".logs",

      # Temporary
      ".tmp",
      "tmp",
      ".temp",
      "temp",

      # Private/secrets (handled by credentials_file checks)
      ".env.local",
      ".env.*.local",
      "secrets",
      ".secrets"
    ]
  end

  @doc """
  List sensitive file extensions that should never be indexed.
  """
  def sensitive_extensions do
    [
      # Executables/Binaries
      ".exe",
      ".dll",
      ".so",
      ".dylib",
      ".bin",
      ".app",
      ".apk",
      ".ipa",

      # Compiled
      ".o",
      ".obj",
      ".a",
      ".lib",
      ".class",
      ".jar",
      ".pyc",
      ".beam",
      ".wasm",
      ".elc",

      # Archives
      ".zip",
      ".tar",
      ".gz",
      ".bz2",
      ".7z",
      ".rar",
      ".xz",

      # Encrypted/Encoded
      ".gpg",
      ".pgp",
      ".enc",
      ".der",
      ".p12",
      ".pfx",
      ".jks",

      # Credentials
      ".pem",
      ".key",
      ".crt",
      ".cer",
      ".pub",
      ".rsa",
      ".private",

      # Documents (usually not code)
      ".pdf",
      ".doc",
      ".docx",
      ".xls",
      ".xlsx",
      ".ppt",
      ".pptx",

      # Media
      ".mp3",
      ".mp4",
      ".avi",
      ".mov",
      ".mkv",
      ".flv",
      ".wav",
      ".flac",
      ".aac",
      ".jpg",
      ".jpeg",
      ".png",
      ".gif",
      ".webp",
      ".svg",
      ".ico",

      # Database
      ".db",
      ".sqlite",
      ".sqlite3",
      ".mdb",
      ".accdb",
      ".ibd",
      ".frm"
    ]
  end

  @doc """
  List filename patterns that typically contain credentials.
  """
  def credentials_patterns do
    [
      # Environment files
      ~r/\.env/,
      ~r/\.env\..+/,
      ~r/config.*\.local/,
      ~r/secret/i,
      ~r/credential/i,
      ~r/password/i,
      ~r/api[_-]?key/i,
      ~r/oauth/i,
      ~r/token/i,
      ~r/auth/i,

      # Cloud provider configs
      ~r/^\.aws$/,
      ~r/^\.gcp$/,
      ~r/^\.azure$/,
      ~r/^gcloud.*config/i,
      ~r/^aws.*config/i,
      ~r/service[_-]?account/i,

      # SSH/Auth
      ~r/^\.ssh$/,
      ~r/^\.kube$/,
      ~r/^config$/i,
      ~r/^known_hosts$/i,
      ~r/^authorized_keys$/i,
      ~r/private[_-]?key/i,
      ~r/certificate/i,

      # Database credentials
      ~r/\.pgpass/,
      ~r/\.mypass/,
      ~r/db[_-]?password/i,
      ~r/connection[_-]?string/i,
      ~r/database[_-]?url/i,

      # API/Service credentials
      ~r/api[_-]?secret/i,
      ~r/private[_-]?key/i,
      ~r/app[_-]?secret/i,
      ~r/signing[_-]?key/i,

      # NPM/Yarn tokens
      ~r/\.npmrc/,
      ~r/\.yarnrc/,
      ~r/npm[_-]?token/i,
      ~r/yarn[_-]?token/i
    ]
  end

  # Private

  defp is_private_directory?(filepath) do
    path_parts = String.split(filepath, "/")

    private_dirs = private_directories()

    Enum.any?(path_parts, fn part ->
      Enum.member?(private_dirs, part)
    end)
  end

  defp is_sensitive_file?(filepath) do
    ext = filepath |> String.downcase() |> Path.extname()
    Enum.member?(sensitive_extensions(), ext)
  end

  defp is_credentials_file?(filepath) do
    filename = Path.basename(filepath) |> String.downcase()

    Enum.any?(credentials_patterns(), fn pattern ->
      Regex.match?(pattern, filename)
    end)
  end

  defp is_excluded_by_gitignore?(filepath, patterns) when is_list(patterns) do
    Enum.any?(patterns, fn pattern ->
      path_matches_pattern?(filepath, pattern)
    end)
  end

  defp is_excluded_by_gitignore?(_filepath, _patterns), do: false

  defp is_secrets_by_content?(filepath, false), do: false

  defp is_secrets_by_content?(filepath, true) do
    try do
      content = File.read!(filepath)

      # Simple heuristic: check for common secret patterns
      secret_indicators = [
        ~r/private[_-]?key/i,
        ~r/-----BEGIN.*KEY-----/,
        ~r/-----BEGIN.*CERTIFICATE-----/,
        ~r/aws_access_key_id/i,
        ~r/aws_secret_access_key/i,
        ~r/AKIA[0-9A-Z]{16}/,
        ~r/api[_-]?key\s*[:=]/i,
        ~r/password\s*[:=]/i,
        ~r/secret\s*[:=]/i,
        ~r/token\s*[:=]/i
      ]

      Enum.any?(secret_indicators, fn pattern ->
        Regex.match?(pattern, content)
      end)
    rescue
      _e -> false
    end
  end

  defp path_matches_pattern?(path, pattern) do
    cond do
      pattern == path ->
        true

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
end
