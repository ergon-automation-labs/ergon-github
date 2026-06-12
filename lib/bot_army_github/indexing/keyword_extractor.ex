defmodule BotArmyGithub.Indexing.KeywordExtractor do
  @moduledoc """
  Extracts programming keywords and identifiers from source code.

  Supports language-specific extraction:
  - Function/method definitions
  - Class/module/struct definitions
  - Variable declarations
  - Type annotations
  - Import/require statements

  Filters out common keywords and noise.
  """

  require Logger

  alias BotArmyGithub.Indexing.LanguageDetector

  @doc """
  Extract keywords from a file path.

  Returns:
    {:ok, %{keywords: [string], count: integer}}
    {:error, reason}
  """
  def extract_from_file(filepath, opts \\ []) do
    with {:ok, content} <- File.read(filepath),
         language <- LanguageDetector.detect(filepath),
         {:ok, keywords} <- extract_keywords(content, language, opts) do
      {:ok, keywords}
    else
      error -> error
    end
  end

  @doc """
  Extract keywords from source code content.

  Returns:
    {:ok, %{keywords: [string], count: integer, duplicates: integer}}
    {:error, reason}
  """
  def extract_keywords(content, language, opts \\ [])
      when is_binary(content) and is_atom(language) do
    try do
      min_length = Keyword.get(opts, :min_length, 3)
      max_length = Keyword.get(opts, :max_length, 50)
      include_common = Keyword.get(opts, :include_common, false)

      patterns = patterns_for_language(language)

      all_keywords = extract_all_keywords(content, patterns)

      keywords =
        all_keywords
        |> filter_keywords(language, min_length, max_length, include_common)
        |> Enum.uniq()

      duplicates = Enum.count(all_keywords) - Enum.count(keywords)

      {:ok,
       %{
         keywords: keywords,
         count: Enum.count(keywords),
         duplicates: duplicates,
         language: language
       }}
    rescue
      e ->
        Logger.error("Error extracting keywords: #{inspect(e)}")
        {:error, {:extraction_failed, e}}
    end
  end

  @doc """
  Get regex patterns for a specific language.
  """
  def patterns_for_language(language) do
    case language do
      :elixir -> elixir_patterns()
      :python -> python_patterns()
      :javascript -> javascript_patterns()
      :typescript -> typescript_patterns()
      :go -> go_patterns()
      :rust -> rust_patterns()
      :java -> java_patterns()
      :ruby -> ruby_patterns()
      :cpp -> cpp_patterns()
      :c -> c_patterns()
      _ -> generic_patterns()
    end
  end

  @doc """
  Classify a keyword by type: function, class, variable, import, etc.
  """
  def classify_keyword(keyword, _language \\ :unknown) do
    cond do
      String.match?(keyword, ~r/^(import|require|use|include)/) -> :import
      String.match?(keyword, ~r/^(def|function|fn|func|method)/) -> :function
      String.match?(keyword, ~r/^(class|module|struct|interface|trait)/) -> :class
      String.match?(keyword, ~r/^[A-Z]/) -> :constant
      String.match?(keyword, ~r/_$/) -> :variable
      true -> :identifier
    end
  end

  # Private

  defp extract_all_keywords(content, patterns) do
    patterns
    |> Enum.flat_map(fn pattern ->
      Regex.scan(pattern, content)
      |> Enum.map(fn
        [match] -> match
        [_, capture | _] -> capture
        match -> List.last(match) || List.first(match)
      end)
    end)
  end

  defp filter_keywords(keywords, language, min_length, max_length, include_common) do
    keywords
    |> Enum.reject(fn kw ->
      String.length(kw) < min_length or String.length(kw) > max_length
    end)
    |> Enum.reject(fn kw ->
      is_common_keyword?(kw, language, include_common)
    end)
    |> Enum.reject(fn kw ->
      is_numeric_or_operator?(kw)
    end)
    |> Enum.map(&String.downcase/1)
  end

  defp is_common_keyword?(keyword, language, include_common) do
    if include_common do
      false
    else
      common = common_keywords() ++ language_common_keywords(language)
      Enum.member?(common, String.downcase(keyword))
    end
  end

  defp is_numeric_or_operator?(keyword) do
    String.match?(keyword, ~r/^[\d\+\-\*\/\=\&\|\^\~\!\@\#\$\%\<\>\?]+$/)
  end

  # Language-specific patterns

  defp elixir_patterns do
    [
      ~r/def\s+(\w+)/,
      ~r/defmodule\s+([A-Z]\w*(?:\.[A-Z]\w*)*)/,
      ~r/defstruct\s+.*?(\w+):/,
      ~r/@(\w+)/,
      ~r/alias\s+([A-Z][\w.]*)/,
      ~r/import\s+([A-Z][\w.]*)/,
      ~r/use\s+([A-Z][\w.]*)/,
      ~r/require\s+([A-Z][\w.]*)/,
      ~r/\b(\w+)\s*\(/
    ]
  end

  defp python_patterns do
    [
      ~r/def\s+(\w+)/,
      ~r/class\s+(\w+)/,
      ~r/from\s+([a-z_][a-z0-9_.]*)/,
      ~r/import\s+([a-z_][a-z0-9_.]*)/,
      ~r/@(\w+)/,
      ~r/(\w+)\s*=/,
      ~r/\b([a-z_]\w*)\s*\(/
    ]
  end

  defp javascript_patterns do
    [
      ~r/function\s+(\w+)/,
      ~r/class\s+(\w+)/,
      ~r/const\s+(\w+)/,
      ~r/let\s+(\w+)/,
      ~r/var\s+(\w+)/,
      ~r{import\s+.*from\s+['"]+([\w/@.-]+)['"]},
      ~r{require\s*\(\s*['"]+([\w/@.-]+)['"]\s*\)},
      ~r/export\s+(?:default\s+)?(?:function|class)?\s+(\w+)/,
      ~r/\b([a-z_]\w*)\s*\(/
    ]
  end

  defp typescript_patterns do
    [
      ~r/function\s+(\w+)/,
      ~r/class\s+(\w+)/,
      ~r/interface\s+(\w+)/,
      ~r/type\s+(\w+)/,
      ~r/const\s+(\w+)/,
      ~r/let\s+(\w+)/,
      ~r/var\s+(\w+)/,
      ~r{import\s+.*from\s+['"]+([\w/@.-]+)['"]},
      ~r/\b([a-z_]\w*)\s*\(/
    ]
  end

  defp go_patterns do
    [
      ~r/func\s+\(([a-z_]\w*)\s+\*?(\w+)\)\s+(\w+)/,
      ~r/func\s+(\w+)/,
      ~r/type\s+(\w+)\s+struct/,
      ~r/type\s+(\w+)\s+interface/,
      ~r/package\s+(\w+)/,
      ~r{import\s+['"]+([\w/@.-]+)['"]},
      ~r/\bvar\s+(\w+)/,
      ~r/\bconst\s+(\w+)/
    ]
  end

  defp rust_patterns do
    [
      ~r/fn\s+(\w+)/,
      ~r/struct\s+(\w+)/,
      ~r/trait\s+(\w+)/,
      ~r/enum\s+(\w+)/,
      ~r/type\s+(\w+)/,
      ~r/impl\s+(<.*?>\s+)?(\w+)/,
      ~r/use\s+([a-z_::\w]*)/,
      ~r/mod\s+(\w+)/,
      ~r/const\s+(\w+)/,
      ~r/let\s+mut\s+(\w+)/,
      ~r/let\s+(\w+)/
    ]
  end

  defp java_patterns do
    [
      ~r/public\s+(?:static\s+)?(?:class|interface|enum)\s+(\w+)/,
      ~r/(?:public|private|protected)\s+(?:static\s+)?(?:final\s+)?(?:class|interface)\s+(\w+)/,
      ~r/public\s+(?:static\s+)?(?:final\s+)?(\w+)\s+(\w+)\s*[=;]/,
      ~r/private\s+(?:static\s+)?(?:final\s+)?(\w+)\s+(\w+)\s*[=;]/,
      ~r/public\s+(?:static\s+)?(\w+)\s+(\w+)\s*\(/,
      ~r/import\s+([a-z][a-z0-9.]*(?:\.\*)?)/,
      ~r/package\s+([a-z][a-z0-9.]*)/
    ]
  end

  defp ruby_patterns do
    [
      ~r/def\s+(\w+)/,
      ~r/class\s+(\w+)/,
      ~r/module\s+(\w+)/,
      ~r{require\s+['"]+([\w/@.-]+)['"]},
      ~r/attr_(?:accessor|reader|writer)\s+:(\w+)/,
      ~r/@(\w+)/,
      ~r/\b(\w+)\s*=/,
      ~r/\b([a-z_]\w*)\s*\(/
    ]
  end

  defp cpp_patterns do
    [
      ~r/(?:class|struct)\s+(\w+)/,
      ~r/(?:void|int|float|double|bool|char|string)\s+(\w+)\s*\(/,
      ~r/namespace\s+(\w+)/,
      ~r{#include\s+[<"]+([\w/.-]+)[>"]},
      ~r/using\s+(?:namespace\s+)?([a-z_::\w]*)/,
      ~r/typedef\s+(?:struct|class)?\s+(\w+)/,
      ~r/\bconst\s+(\w+)/,
      ~r/template\s*<[^>]+>\s+(?:class|struct|void|int|float|double|bool|char|string)\s+(\w+)/
    ]
  end

  defp c_patterns do
    [
      ~r/(?:void|int|float|double|bool|char|unsigned|struct)\s+(\w+)\s*\(/,
      ~r/(?:struct|typedef)\s+(\w+)/,
      ~r{#include\s+[<"]+([\w/.-]+)[>"]},
      ~r/#define\s+(\w+)/,
      ~r/\bconst\s+(?:int|float|double|char|void)\s+(\w+)/,
      ~r/(?:static\s+)?(?:inline\s+)?(?:unsigned\s+)?(?:int|float|double|char|void)\s+(\w+)\s*\(/
    ]
  end

  defp generic_patterns do
    [
      ~r/(?:def|function|func|fn)\s+(\w+)/,
      ~r/(?:class|struct|interface|trait)\s+(\w+)/,
      ~r{(?:import|require|use|include)\s+['"]+([\w/@.-]+)['"]},
      ~r/\b([A-Z]\w*)\b/,
      ~r/\b([a-z_]\w+)\s*\(/
    ]
  end

  defp common_keywords do
    [
      "the",
      "and",
      "or",
      "not",
      "is",
      "in",
      "if",
      "else",
      "for",
      "while",
      "do",
      "return",
      "true",
      "false",
      "null",
      "nil",
      "none",
      "self",
      "this",
      "that",
      "it",
      "as",
      "to",
      "from",
      "by",
      "with",
      "of",
      "at",
      "on",
      "test",
      "main",
      "data",
      "result",
      "value",
      "item",
      "list",
      "array",
      "map",
      "hash",
      "dict",
      "set",
      "object",
      "error",
      "exception",
      "args",
      "opts",
      "params",
      "config"
    ]
  end

  defp language_common_keywords(:elixir) do
    [
      "defmodule",
      "defstruct",
      "defprotocol",
      "defimpl",
      "do",
      "end",
      "when",
      "case",
      "cond",
      "receive",
      "try",
      "catch",
      "after",
      "else"
    ]
  end

  defp language_common_keywords(:python) do
    [
      "def",
      "class",
      "if",
      "else",
      "elif",
      "for",
      "while",
      "try",
      "except",
      "finally",
      "with",
      "as",
      "import",
      "from",
      "return",
      "yield",
      "lambda",
      "and",
      "or",
      "not",
      "in",
      "is"
    ]
  end

  defp language_common_keywords(:javascript) do
    [
      "function",
      "class",
      "const",
      "let",
      "var",
      "if",
      "else",
      "for",
      "while",
      "do",
      "switch",
      "case",
      "break",
      "continue",
      "return",
      "try",
      "catch",
      "finally",
      "throw",
      "import",
      "export",
      "default",
      "async",
      "await",
      "new",
      "this",
      "super"
    ]
  end

  defp language_common_keywords(:go) do
    [
      "package",
      "import",
      "func",
      "type",
      "interface",
      "struct",
      "const",
      "var",
      "if",
      "else",
      "for",
      "range",
      "switch",
      "case",
      "default",
      "defer",
      "go",
      "select",
      "chan",
      "return"
    ]
  end

  defp language_common_keywords(:rust) do
    [
      "fn",
      "let",
      "mut",
      "const",
      "static",
      "struct",
      "trait",
      "impl",
      "enum",
      "match",
      "if",
      "else",
      "loop",
      "while",
      "for",
      "in",
      "use",
      "mod",
      "pub",
      "crate",
      "unsafe",
      "async",
      "await"
    ]
  end

  defp language_common_keywords(:java) do
    [
      "public",
      "private",
      "protected",
      "static",
      "final",
      "abstract",
      "class",
      "interface",
      "enum",
      "extends",
      "implements",
      "new",
      "if",
      "else",
      "for",
      "while",
      "do",
      "switch",
      "case",
      "break",
      "continue",
      "return",
      "try",
      "catch",
      "finally",
      "throw",
      "throws",
      "import",
      "package",
      "synchronized",
      "volatile"
    ]
  end

  defp language_common_keywords(_), do: []
end
