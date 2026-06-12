defmodule BotArmyGithub.Indexing.LanguageDetector do
  @moduledoc """
  Detects programming languages from file content and metadata.

  Supports detection by:
  - File extension (primary)
  - Shebang line (for scripts)
  - File content patterns
  - Known filenames (Dockerfile, Makefile, etc)
  """

  require Logger

  @doc """
  Detect language from file path and optionally content.

  Returns an atom representing the detected language or :unknown
  """
  def detect(filepath, opts \\ []) do
    read_content = Keyword.get(opts, :read_content, false)

    cond do
      # Check filename first (Dockerfile, Makefile, etc)
      lang = detect_by_filename(filepath) ->
        lang

      # Check extension
      lang = detect_by_extension(filepath) ->
        lang

      # Check content if file has no extension or requested
      read_content and File.exists?(filepath) ->
        detect_by_content(filepath)

      # Last attempt: if no extension and file exists, try content
      Path.extname(filepath) == "" and File.exists?(filepath) ->
        detect_by_content(filepath)

      true ->
        :unknown
    end
  end

  @doc """
  Get a human-readable name for a language atom.
  """
  def language_name(lang) do
    language_names()
    |> Map.get(lang, "Unknown")
  end

  @doc """
  Get the file extension typically used for a language.
  """
  def canonical_extension(lang) do
    extension_for_language()
    |> Map.get(lang)
  end

  @doc """
  Classify language into a category: :compiled, :interpreted, :markup, :data, :unknown
  """
  def language_category(lang) do
    categories()
    |> Map.get(lang, :unknown)
  end

  # Private

  defp detect_by_filename(filepath) do
    filename = Path.basename(filepath)

    case filename do
      "Dockerfile" -> :dockerfile
      "Makefile" -> :makefile
      "Gemfile" -> :ruby
      "Rakefile" -> :ruby
      "Podfile" -> :ruby
      "Cartfile" -> :swift
      "Appfile" -> :ruby
      "Fastfile" -> :ruby
      "Guardfile" -> :ruby
      "Procfile" -> :bash
      "mix.exs" -> :elixir
      "rebar.config" -> :erlang
      ".travis.yml" -> :yaml
      ".gitignore" -> :text
      _ -> nil
    end
  end

  defp detect_by_extension(filepath) do
    ext = filepath |> Path.extname() |> String.downcase()
    extension_map() |> Map.get(ext)
  end

  defp detect_by_content(filepath) do
    try do
      content = File.read!(filepath)

      cond do
        String.starts_with?(content, "#!/usr/bin/env python") -> :python
        String.starts_with?(content, "#!/usr/bin/python") -> :python
        String.starts_with?(content, "#!/bin/bash") -> :bash
        String.starts_with?(content, "#!/bin/sh") -> :bash
        String.starts_with?(content, "#!/usr/bin/env ruby") -> :ruby
        String.starts_with?(content, "#!") -> detect_shebang(content)
        String.starts_with?(content, "<?php") -> :php
        String.starts_with?(content, "<%") -> :erb
        true -> :unknown
      end
    rescue
      _ -> :unknown
    end
  end

  defp detect_shebang(content) do
    content
    |> String.split("\n")
    |> List.first("")
    |> String.downcase()
    |> then(fn shebang ->
      cond do
        String.contains?(shebang, "python") -> :python
        String.contains?(shebang, "ruby") -> :ruby
        String.contains?(shebang, "perl") -> :perl
        String.contains?(shebang, "node") -> :javascript
        String.contains?(shebang, "bash") or String.contains?(shebang, "sh") -> :bash
        true -> :bash
      end
    end)
  end

  defp extension_map do
    %{
      # Elixir/Erlang
      ".ex" => :elixir,
      ".exs" => :elixir,
      ".erl" => :erlang,
      ".hrl" => :erlang,
      # Python
      ".py" => :python,
      ".pyi" => :python,
      ".pyx" => :python,
      # JavaScript/TypeScript
      ".js" => :javascript,
      ".mjs" => :javascript,
      ".cjs" => :javascript,
      ".ts" => :typescript,
      ".tsx" => :typescript,
      ".jsx" => :javascript,
      # Go
      ".go" => :go,
      # Rust
      ".rs" => :rust,
      # C/C++
      ".c" => :c,
      ".h" => :c,
      ".hpp" => :cpp,
      ".cpp" => :cpp,
      ".cc" => :cpp,
      ".cxx" => :cpp,
      # Java
      ".java" => :java,
      ".class" => :java,
      ".jar" => :java,
      # Kotlin
      ".kt" => :kotlin,
      ".kts" => :kotlin,
      # Scala
      ".scala" => :scala,
      # Ruby
      ".rb" => :ruby,
      ".rbw" => :ruby,
      # PHP
      ".php" => :php,
      ".phtml" => :php,
      ".php3" => :php,
      # Swift
      ".swift" => :swift,
      # Perl
      ".pl" => :perl,
      ".pm" => :perl,
      # Shell
      ".sh" => :bash,
      ".bash" => :bash,
      ".zsh" => :bash,
      ".fish" => :bash,
      # Markup
      ".html" => :html,
      ".htm" => :html,
      ".xml" => :xml,
      ".md" => :markdown,
      ".markdown" => :markdown,
      ".mdown" => :markdown,
      ".rst" => :rst,
      ".tex" => :latex,
      ".asciidoc" => :asciidoc,
      ".adoc" => :asciidoc,
      # Data/Config
      ".json" => :json,
      ".yaml" => :yaml,
      ".yml" => :yaml,
      ".toml" => :toml,
      ".ini" => :ini,
      ".conf" => :conf,
      ".config" => :conf,
      ".env" => :env,
      ".csv" => :csv,
      ".tsv" => :tsv,
      # SQL
      ".sql" => :sql,
      ".plsql" => :sql,
      # Other
      ".css" => :css,
      ".scss" => :scss,
      ".sass" => :scss,
      ".less" => :less,
      ".dockerfile" => :dockerfile,
      ".gitignore" => :text,
      ".txt" => :text,
      ".log" => :text
    }
  end

  defp language_names do
    %{
      elixir: "Elixir",
      erlang: "Erlang",
      python: "Python",
      javascript: "JavaScript",
      typescript: "TypeScript",
      go: "Go",
      rust: "Rust",
      c: "C",
      cpp: "C++",
      java: "Java",
      kotlin: "Kotlin",
      scala: "Scala",
      ruby: "Ruby",
      php: "PHP",
      swift: "Swift",
      perl: "Perl",
      bash: "Bash",
      html: "HTML",
      xml: "XML",
      markdown: "Markdown",
      rst: "reStructuredText",
      latex: "LaTeX",
      json: "JSON",
      yaml: "YAML",
      toml: "TOML",
      ini: "INI",
      conf: "Configuration",
      env: "Environment",
      css: "CSS",
      scss: "SCSS",
      sass: "SASS",
      less: "LESS",
      sql: "SQL",
      dockerfile: "Dockerfile",
      makefile: "Makefile",
      text: "Text",
      unknown: "Unknown"
    }
  end

  defp extension_for_language do
    %{
      elixir: ".ex",
      erlang: ".erl",
      python: ".py",
      javascript: ".js",
      typescript: ".ts",
      go: ".go",
      rust: ".rs",
      c: ".c",
      cpp: ".cpp",
      java: ".java",
      kotlin: ".kt",
      scala: ".scala",
      ruby: ".rb",
      php: ".php",
      swift: ".swift",
      perl: ".pl",
      bash: ".sh",
      html: ".html",
      xml: ".xml",
      markdown: ".md",
      json: ".json",
      yaml: ".yaml",
      toml: ".toml",
      sql: ".sql",
      dockerfile: "Dockerfile",
      makefile: "Makefile"
    }
  end

  defp categories do
    %{
      # Compiled languages
      erlang: :compiled,
      go: :compiled,
      rust: :compiled,
      c: :compiled,
      cpp: :compiled,
      java: :compiled,
      kotlin: :compiled,
      scala: :compiled,
      # Interpreted languages
      elixir: :interpreted,
      python: :interpreted,
      javascript: :interpreted,
      ruby: :interpreted,
      php: :interpreted,
      swift: :interpreted,
      perl: :interpreted,
      bash: :interpreted,
      # Markup
      html: :markup,
      xml: :markup,
      markdown: :markup,
      rst: :markup,
      latex: :markup,
      # Data/Config
      json: :data,
      yaml: :data,
      toml: :data,
      ini: :data,
      conf: :data,
      env: :data,
      csv: :data,
      tsv: :data,
      # Stylesheets
      css: :stylesheet,
      scss: :stylesheet,
      sass: :stylesheet,
      less: :stylesheet,
      # Other
      sql: :query,
      dockerfile: :container,
      makefile: :build,
      text: :text,
      erb: :template,
      unknown: :unknown
    }
  end
end
