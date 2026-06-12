defmodule BotArmyGithub.Indexing.LanguageDetectorTest do
  use ExUnit.Case
  @moduletag :indexing

  alias BotArmyGithub.Indexing.LanguageDetector

  describe "detect/2 by extension" do
    test "detects common source files" do
      assert LanguageDetector.detect("main.ex") == :elixir
      assert LanguageDetector.detect("main.py") == :python
      assert LanguageDetector.detect("main.js") == :javascript
      assert LanguageDetector.detect("main.go") == :go
      assert LanguageDetector.detect("main.rs") == :rust
    end

    test "detects markup languages" do
      assert LanguageDetector.detect("readme.md") == :markdown
      assert LanguageDetector.detect("index.html") == :html
      assert LanguageDetector.detect("data.xml") == :xml
    end

    test "detects data formats" do
      assert LanguageDetector.detect("config.json") == :json
      assert LanguageDetector.detect("config.yaml") == :yaml
      assert LanguageDetector.detect("config.toml") == :toml
    end

    test "returns unknown for unrecognized extensions" do
      assert LanguageDetector.detect("file.unknown") == :unknown
      assert LanguageDetector.detect("noextension") == :unknown
    end
  end

  describe "detect/2 by filename" do
    test "detects known filenames" do
      assert LanguageDetector.detect("Dockerfile") == :dockerfile
      assert LanguageDetector.detect("Makefile") == :makefile
      assert LanguageDetector.detect("mix.exs") == :elixir
      assert LanguageDetector.detect("Gemfile") == :ruby
    end
  end

  describe "detect/2 with content" do
    setup do
      test_dir = Path.join(System.tmp_dir!(), "detector_test_#{System.unique_integer()}")
      File.mkdir_p!(test_dir)

      on_exit(fn ->
        File.rm_rf!(test_dir)
      end)

      {:ok, test_dir: test_dir}
    end

    test "detects python from shebang", %{test_dir: test_dir} do
      script_path = Path.join(test_dir, "script")
      File.write!(script_path, "#!/usr/bin/env python\nprint('hello')")

      assert LanguageDetector.detect(script_path, read_content: true) == :python
    end

    test "detects bash from shebang", %{test_dir: test_dir} do
      script_path = Path.join(test_dir, "script.sh")
      File.write!(script_path, "#!/bin/bash\necho 'hello'")

      assert LanguageDetector.detect(script_path, read_content: true) == :bash
    end

    test "prefers filename over content", %{test_dir: test_dir} do
      makefile_path = Path.join(test_dir, "Makefile")
      File.write!(makefile_path, "#!/usr/bin/env python\necho hello")

      assert LanguageDetector.detect(makefile_path) == :makefile
    end
  end

  describe "language_name/1" do
    test "returns human-readable names" do
      assert LanguageDetector.language_name(:elixir) == "Elixir"
      assert LanguageDetector.language_name(:python) == "Python"
      assert LanguageDetector.language_name(:markdown) == "Markdown"
      assert LanguageDetector.language_name(:unknown) == "Unknown"
    end
  end

  describe "canonical_extension/1" do
    test "returns typical extension for language" do
      assert LanguageDetector.canonical_extension(:elixir) == ".ex"
      assert LanguageDetector.canonical_extension(:python) == ".py"
      assert LanguageDetector.canonical_extension(:javascript) == ".js"
      assert LanguageDetector.canonical_extension(:dockerfile) == "Dockerfile"
    end

    test "returns nil for unknown languages" do
      assert LanguageDetector.canonical_extension(:unknown) == nil
    end
  end

  describe "language_category/1" do
    test "categorizes compiled languages" do
      assert LanguageDetector.language_category(:go) == :compiled
      assert LanguageDetector.language_category(:rust) == :compiled
      assert LanguageDetector.language_category(:java) == :compiled
    end

    test "categorizes interpreted languages" do
      assert LanguageDetector.language_category(:elixir) == :interpreted
      assert LanguageDetector.language_category(:python) == :interpreted
      assert LanguageDetector.language_category(:javascript) == :interpreted
    end

    test "categorizes markup languages" do
      assert LanguageDetector.language_category(:html) == :markup
      assert LanguageDetector.language_category(:markdown) == :markup
      assert LanguageDetector.language_category(:xml) == :markup
    end

    test "categorizes data formats" do
      assert LanguageDetector.language_category(:json) == :data
      assert LanguageDetector.language_category(:yaml) == :data
      assert LanguageDetector.language_category(:toml) == :data
    end

    test "categorizes other types" do
      assert LanguageDetector.language_category(:dockerfile) == :container
      assert LanguageDetector.language_category(:makefile) == :build
      assert LanguageDetector.language_category(:css) == :stylesheet
    end
  end
end
