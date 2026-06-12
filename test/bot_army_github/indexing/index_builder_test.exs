defmodule BotArmyGithub.Indexing.IndexBuilderTest do
  use ExUnit.Case
  @moduletag :indexing

  alias BotArmyGithub.Indexing.IndexBuilder

  setup do
    test_dir = Path.join(System.tmp_dir!(), "index_test_#{System.unique_integer()}")
    File.mkdir_p!(test_dir)

    # Create test files
    File.write!(Path.join(test_dir, "hello.ex"), """
    defmodule HelloWorld do
      def greet(name) do
        "Hello, " <> name <> "!"
      end

      def goodbye(name) do
        "Goodbye, " <> name <> "!"
      end
    end
    """)

    File.write!(Path.join(test_dir, "utils.ex"), """
    defmodule Utils do
      def add(a, b) do
        a + b
      end

      def multiply(a, b) do
        a * b
      end
    end
    """)

    File.write!(Path.join(test_dir, "script.py"), """
    def hello_python():
        return "Hello from Python"

    def process_data(data):
        return [x * 2 for x in data]
    """)

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

    {:ok, test_dir: test_dir}
  end

  describe "new_index/0" do
    test "creates an empty index" do
      index = IndexBuilder.new_index()

      assert index.keyword_index == %{}
      assert index.files == %{}
      assert index.languages == %{}
      assert index.statistics.total_files == 0
      assert index.statistics.total_keywords == 0
    end
  end

  describe "build_from_repo/2" do
    test "builds index from repository", %{test_dir: test_dir} do
      {:ok, index} = IndexBuilder.build_from_repo(test_dir)

      assert map_size(index.files) == 3
      assert map_size(index.keyword_index) > 0
      assert index.statistics.total_files == 3
      assert index.statistics.total_keywords > 0
    end

    test "indexes files by language", %{test_dir: test_dir} do
      {:ok, index} = IndexBuilder.build_from_repo(test_dir)

      assert Map.has_key?(index.languages, :elixir)
      assert Map.has_key?(index.languages, :python)
      assert length(index.languages[:elixir]) == 2
      assert length(index.languages[:python]) == 1
    end

    test "extracts keywords for each file", %{test_dir: test_dir} do
      {:ok, index} = IndexBuilder.build_from_repo(test_dir)

      files = Map.values(index.files)
      assert Enum.all?(files, &(&1.keyword_count > 0))
      assert Enum.any?(files, &("greet" in &1.keywords or "helloworld" in &1.keywords))
    end
  end

  describe "search/3" do
    setup %{test_dir: test_dir} do
      {:ok, index} = IndexBuilder.build_from_repo(test_dir)
      {:ok, index: index}
    end

    test "searches by keyword", %{index: index} do
      {:ok, result} = IndexBuilder.search(index, "greet")

      assert result.count > 0
      assert Enum.any?(result.results, &String.contains?(&1.path, "hello.ex"))
    end

    test "searches multiple keywords", %{index: index} do
      {:ok, result} = IndexBuilder.search(index, "add multiply")

      assert result.count > 0
      assert Enum.any?(result.results, &String.contains?(&1.path, "utils.ex"))
    end

    test "filters by language", %{index: index} do
      {:ok, result} = IndexBuilder.search(index, "def", language: :elixir)

      assert Enum.all?(result.results, &(&1.language == :elixir))
    end

    test "respects limit option", %{index: index} do
      {:ok, result} = IndexBuilder.search(index, "def", limit: 1)

      assert result.count <= 1
    end

    test "ranks results by relevance", %{index: index} do
      {:ok, result} = IndexBuilder.search(index, "greet goodbye")

      assert result.count > 0
      scores = Enum.map(result.results, & &1.score)
      assert scores == Enum.sort(scores, :desc)
    end

    test "respects min_matches option", %{index: index} do
      {:ok, result1} = IndexBuilder.search(index, "greet goodbye", min_matches: 1)
      {:ok, result2} = IndexBuilder.search(index, "greet goodbye", min_matches: 2)

      assert result1.count >= result2.count
    end
  end

  describe "search_files/3" do
    setup %{test_dir: test_dir} do
      {:ok, index} = IndexBuilder.build_from_repo(test_dir)
      {:ok, index: index}
    end

    test "searches by path pattern", %{index: index} do
      {:ok, result} = IndexBuilder.search_files(index, "hello")

      assert result.count >= 1
      assert Enum.any?(result.results, &String.contains?(&1.path, "hello.ex"))
    end

    test "case-insensitive search", %{index: index} do
      {:ok, result1} = IndexBuilder.search_files(index, "hello")
      {:ok, result2} = IndexBuilder.search_files(index, "HELLO")

      assert result1.count == result2.count
    end

    test "respects limit option", %{index: index} do
      {:ok, result} = IndexBuilder.search_files(index, "ex", limit: 1)

      assert result.count <= 1
    end
  end

  describe "get_files_by_language/3" do
    setup %{test_dir: test_dir} do
      {:ok, index} = IndexBuilder.build_from_repo(test_dir)
      {:ok, index: index}
    end

    test "retrieves files by language", %{index: index} do
      {:ok, result} = IndexBuilder.get_files_by_language(index, :elixir)

      assert result.count == 2
      assert Enum.all?(result.results, &(&1.language == :elixir))
    end

    test "handles empty language", %{index: index} do
      {:ok, result} = IndexBuilder.get_files_by_language(index, :unknown_language)

      assert result.count == 0
    end
  end

  describe "get_file/2" do
    setup %{test_dir: test_dir} do
      {:ok, index} = IndexBuilder.build_from_repo(test_dir)
      {:ok, index: index}
    end

    test "retrieves file by ID", %{index: index} do
      [file | _] = Map.values(index.files)

      {:ok, retrieved} = IndexBuilder.get_file(index, file.id)

      assert retrieved.id == file.id
      assert retrieved.path == file.path
      assert retrieved.language == file.language
    end

    test "returns error for non-existent ID", %{index: index} do
      {:error, :not_found} = IndexBuilder.get_file(index, 999)
    end
  end

  describe "list_files/2" do
    setup %{test_dir: test_dir} do
      {:ok, index} = IndexBuilder.build_from_repo(test_dir)
      {:ok, index: index}
    end

    test "lists all files", %{index: index} do
      {:ok, result} = IndexBuilder.list_files(index)

      assert result.count == 3
      assert result.total == 3
    end

    test "respects limit and offset", %{index: index} do
      {:ok, result} = IndexBuilder.list_files(index, limit: 2, offset: 1)

      assert result.count == 2
      assert result.offset == 1
    end
  end

  describe "list_keywords/2" do
    setup %{test_dir: test_dir} do
      {:ok, index} = IndexBuilder.build_from_repo(test_dir)
      {:ok, index: index}
    end

    test "lists all keywords", %{index: index} do
      {:ok, result} = IndexBuilder.list_keywords(index)

      assert result.count > 0
      assert result.total > 0
    end

    test "sorts by frequency", %{index: index} do
      {:ok, result} = IndexBuilder.list_keywords(index)

      frequencies = Enum.map(result.keywords, & &1.frequency)
      assert frequencies == Enum.sort(frequencies, :desc)
    end

    test "respects limit", %{index: index} do
      {:ok, result} = IndexBuilder.list_keywords(index, limit: 5)

      assert result.count <= 5
    end
  end

  describe "statistics/1" do
    setup %{test_dir: test_dir} do
      {:ok, index} = IndexBuilder.build_from_repo(test_dir)
      {:ok, index: index}
    end

    test "returns index statistics", %{index: index} do
      stats = IndexBuilder.statistics(index)

      assert stats.total_files == 3
      assert stats.total_keywords > 0
      assert Map.has_key?(stats.languages, :elixir)
      assert Map.has_key?(stats.languages, :python)
    end
  end

  describe "add_file_to_index/3" do
    setup %{test_dir: test_dir} do
      {:ok, index} = IndexBuilder.build_from_repo(test_dir)
      {:ok, index: index}
    end

    test "adds new file to existing index", %{index: initial_index, test_dir: test_dir} do
      File.write!(Path.join(test_dir, "new_file.ex"), """
      defmodule NewModule do
        def new_function do
          :ok
        end
      end
      """)

      file = %{
        path: "new_file.ex",
        language: :elixir,
        size_bytes: 100,
        is_text: true,
        last_modified: DateTime.utc_now()
      }

      updated_index = IndexBuilder.add_file_to_index(initial_index, file, test_dir)

      assert map_size(updated_index.files) == map_size(initial_index.files) + 1
      assert updated_index.statistics.total_files == initial_index.statistics.total_files + 1
    end
  end
end
