defmodule BotArmyGithub.Indexing.KeywordExtractorTest do
  use ExUnit.Case
  @moduletag :indexing

  alias BotArmyGithub.Indexing.KeywordExtractor

  setup do
    test_dir = Path.join(System.tmp_dir!(), "keyword_test_#{System.unique_integer()}")
    File.mkdir_p!(test_dir)

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

    {:ok, test_dir: test_dir}
  end

  describe "extract_keywords/2 - Elixir" do
    test "extracts function definitions" do
      code = """
      defmodule MyModule do
        def hello_world do
          :ok
        end

        def process_data(data) do
          data
        end
      end
      """

      {:ok, result} = KeywordExtractor.extract_keywords(code, :elixir)

      assert result.language == :elixir
      assert "hello_world" in result.keywords
      assert "process_data" in result.keywords
      assert "mymodule" in result.keywords
    end

    test "filters common keywords" do
      code = "def test_function do :ok end"
      {:ok, result} = KeywordExtractor.extract_keywords(code, :elixir)

      assert "test_function" in result.keywords
      refute "do" in result.keywords
      refute "end" in result.keywords
    end

    test "respects min/max length options" do
      code = "def a do :ok end, def hello_world do :ok end"
      {:ok, result} = KeywordExtractor.extract_keywords(code, :elixir, min_length: 5)

      refute Enum.any?(result.keywords, &(String.length(&1) < 5))
      assert "hello_world" in result.keywords
    end

    test "deduplicates keywords" do
      code = """
      def process do :ok end
      def process do :ok end
      def process do :ok end
      """

      {:ok, result} = KeywordExtractor.extract_keywords(code, :elixir)

      assert Enum.count(Enum.filter(result.keywords, &(&1 == "process"))) == 1
      assert result.duplicates > 0
    end
  end

  describe "extract_keywords/2 - Python" do
    test "extracts function and class definitions" do
      code = """
      class MyClass:
          def __init__(self):
              pass

          def process_data(self, data):
              return data

      def helper_function():
          pass
      """

      {:ok, result} = KeywordExtractor.extract_keywords(code, :python)

      assert "myclass" in result.keywords
      assert "process_data" in result.keywords
      assert "helper_function" in result.keywords
    end

    test "extracts import statements" do
      code = """
      import os
      from typing import List, Dict
      from collections import defaultdict
      """

      {:ok, result} = KeywordExtractor.extract_keywords(code, :python, min_length: 1)

      assert "os" in result.keywords or length(result.keywords) > 0

      assert Enum.any?(
               result.keywords,
               &(String.contains?(&1, "typing") or String.contains?(&1, "collections"))
             )
    end
  end

  describe "extract_keywords/2 - JavaScript" do
    test "extracts function and class definitions" do
      code = """
      function myFunction() {
        return 42;
      }

      class MyClass {
        constructor() {
          this.value = 0;
        }

        myMethod() {
          return this.value;
        }
      }
      """

      {:ok, result} = KeywordExtractor.extract_keywords(code, :javascript)

      assert "myfunction" in result.keywords
      assert "myclass" in result.keywords
      assert Enum.any?(result.keywords, &String.contains?(&1, "method"))
    end

    test "extracts const/let/var declarations" do
      code = """
      const MAX_SIZE = 100;
      let counter = 0;
      var globalVar = 'test';
      """

      {:ok, result} = KeywordExtractor.extract_keywords(code, :javascript)

      assert "max_size" in result.keywords or "max_size" in result.keywords
      assert "counter" in result.keywords
      assert "globalvar" in result.keywords
    end
  end

  describe "extract_keywords/2 - Go" do
    test "extracts function and type definitions" do
      code = """
      package main

      func main() {
        println("Hello")
      }

      type User struct {
        Name string
        Age int
      }

      func (u User) String() string {
        return u.Name
      }
      """

      {:ok, result} = KeywordExtractor.extract_keywords(code, :go)

      assert "user" in result.keywords
      assert Enum.any?(result.keywords, &(String.length(&1) > 2))
    end
  end

  describe "extract_keywords/2 - Rust" do
    test "extracts function and struct definitions" do
      code = """
      fn main() {
        println!("Hello");
      }

      struct Point {
        x: i32,
        y: i32,
      }

      impl Point {
        fn new(x: i32, y: i32) -> Point {
          Point { x, y }
        }
      }
      """

      {:ok, result} = KeywordExtractor.extract_keywords(code, :rust)

      assert "point" in result.keywords
      assert "new" in result.keywords
      assert Enum.count(result.keywords) > 0
    end
  end

  describe "extract_from_file/2" do
    test "extracts keywords from file", %{test_dir: test_dir} do
      file_path = Path.join(test_dir, "test.ex")
      File.write!(file_path, "defmodule HelloWorld do\n  def greet, do: :ok\nend")

      {:ok, result} = KeywordExtractor.extract_from_file(file_path)

      assert result.language == :elixir
      assert "helloworld" in result.keywords
      assert "greet" in result.keywords
    end

    test "returns error for non-existent file" do
      result = KeywordExtractor.extract_from_file("/nonexistent/file.ex")

      assert {:error, _} = result
    end
  end

  describe "classify_keyword/2" do
    test "classifies function keywords" do
      assert KeywordExtractor.classify_keyword("def_function") == :function
      assert KeywordExtractor.classify_keyword("fn_process") == :function
    end

    test "classifies class keywords" do
      assert KeywordExtractor.classify_keyword("class_definition") == :class
      assert KeywordExtractor.classify_keyword("module_helper") == :class
      assert KeywordExtractor.classify_keyword("struct_user") == :class
    end

    test "classifies import keywords" do
      assert KeywordExtractor.classify_keyword("import_module") == :import
      assert KeywordExtractor.classify_keyword("require_helper") == :import
    end

    test "classifies variable keywords" do
      assert KeywordExtractor.classify_keyword("my_var_") == :variable
      assert KeywordExtractor.classify_keyword("temp_") == :variable
    end

    test "classifies constant keywords" do
      assert KeywordExtractor.classify_keyword("CONSTANT") == :constant
      assert KeywordExtractor.classify_keyword("MAX_SIZE") == :constant
    end
  end

  describe "patterns_for_language/1" do
    test "returns elixir patterns" do
      patterns = KeywordExtractor.patterns_for_language(:elixir)
      assert is_list(patterns)
      assert Enum.any?(patterns, &is_struct(&1, Regex))
    end

    test "returns python patterns" do
      patterns = KeywordExtractor.patterns_for_language(:python)
      assert is_list(patterns)
      assert length(patterns) > 0
    end

    test "returns javascript patterns" do
      patterns = KeywordExtractor.patterns_for_language(:javascript)
      assert is_list(patterns)
      assert length(patterns) > 0
    end

    test "returns generic patterns for unknown language" do
      patterns = KeywordExtractor.patterns_for_language(:unknown)
      assert is_list(patterns)
      assert length(patterns) > 0
    end
  end

  describe "edge cases" do
    test "handles empty code" do
      {:ok, result} = KeywordExtractor.extract_keywords("", :elixir)

      assert result.keywords == []
      assert result.count == 0
    end

    test "handles code with only comments" do
      code = """
      # This is a comment
      # Another comment
      """

      {:ok, result} = KeywordExtractor.extract_keywords(code, :python)

      assert result.count == 0
    end

    test "handles code with special characters" do
      code = "def test_func!@#$() do :ok end"
      {:ok, result} = KeywordExtractor.extract_keywords(code, :elixir)

      assert "test_func" in result.keywords
    end

    test "handles unicode in identifiers" do
      code = "def test_café_function do :ok end"
      {:ok, result} = KeywordExtractor.extract_keywords(code, :elixir)

      assert Enum.any?(result.keywords, &String.contains?(&1, "caf"))
    end

    test "respects include_common option" do
      code = "def if_condition do :ok end"
      {:ok, result1} = KeywordExtractor.extract_keywords(code, :elixir, include_common: false)
      {:ok, result2} = KeywordExtractor.extract_keywords(code, :elixir, include_common: true)

      assert result1.count >= result2.count
    end
  end
end
