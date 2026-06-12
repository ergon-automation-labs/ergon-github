defmodule BotArmyGithub.Indexing.DocsPublisherTest do
  use ExUnit.Case
  @moduletag :indexing

  alias BotArmyGithub.Indexing.DocsPublisher
  alias BotArmyGithub.Indexing.IndexBuilder

  setup do
    test_dir = Path.join(System.tmp_dir!(), "publisher_test_#{System.unique_integer()}")
    File.mkdir_p!(test_dir)

    # Create test files and build index
    File.write!(Path.join(test_dir, "test.ex"), """
    defmodule TestModule do
      def test_function do
        :ok
      end
    end
    """)

    {:ok, index} = IndexBuilder.build_from_repo(test_dir)
    files = Map.values(index.files)

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

    {:ok, index: index, files: files, test_dir: test_dir}
  end

  describe "build_file_event/2" do
    test "builds correct event structure for file", %{files: [file | _]} do
      event = DocsPublisher.build_file_event(file, repo_path: "/test/repo")

      assert event.event_id
      assert event.event == "docs.indexed"
      assert event.schema_version == "1.0"
      assert event.source == "github_bot"
      assert event.timestamp
      assert event.payload.path == file.path
      assert event.payload.language == file.language
      assert event.payload.repo_path == "/test/repo"
      assert event.payload.keyword_count > 0
    end

    test "includes file metadata in payload", %{files: [file | _]} do
      event = DocsPublisher.build_file_event(file)

      assert event.payload.file_id == file.id
      assert event.payload.path == file.path
      assert event.payload.language == file.language
      assert event.payload.size_bytes == file.size_bytes
      assert event.payload.keywords == file.keywords
    end

    test "includes top-level fields for context", %{files: [file | _]} do
      event = DocsPublisher.build_file_event(file)

      assert event.file_id == file.id
      assert event.path == file.path
      assert event.language == file.language
      assert event.keyword_count == file.keyword_count
    end

    test "includes timestamp in ISO8601 format", %{files: [file | _]} do
      event = DocsPublisher.build_file_event(file)

      assert String.contains?(event.timestamp, "T")
      assert String.contains?(event.timestamp, "Z") or String.contains?(event.timestamp, "+")
    end
  end

  describe "build_batch_complete_event/2" do
    test "builds batch completion event", %{index: index} do
      event = DocsPublisher.build_batch_complete_event(index, repo_path: "/test/repo")

      assert event.event_id
      assert event.event == "docs.indexed.batch"
      assert event.schema_version == "1.0"
      assert event.source == "github_bot"
      assert event.timestamp
    end

    test "includes statistics in payload", %{index: index} do
      event = DocsPublisher.build_batch_complete_event(index)

      assert event.payload.total_files == index.statistics.total_files
      assert event.payload.total_keywords == index.statistics.total_keywords
      assert event.payload.unique_keywords == map_size(index.keyword_index)
      assert event.payload.languages == index.statistics.languages
      assert event.payload.completion_status == "success"
    end

    test "includes languages list in payload", %{index: index} do
      event = DocsPublisher.build_batch_complete_event(index)

      languages = event.payload.languages_list
      assert is_list(languages)
      assert Enum.all?(languages, &Map.has_key?(&1, :language))
      assert Enum.all?(languages, &Map.has_key?(&1, :file_count))
    end

    test "includes top-level fields for context", %{index: index} do
      event = DocsPublisher.build_batch_complete_event(index)

      assert event.total_files == index.statistics.total_files
      assert event.total_keywords == index.statistics.total_keywords
      assert event.completion_status == "success"
    end
  end

  describe "query_published/2" do
    test "returns query result" do
      {:ok, result} = DocsPublisher.query_published("/test/repo")

      assert result.repo_path == "/test/repo"
      assert result.status == "queried"
    end
  end

  describe "event envelope format" do
    test "file event has required envelope fields", %{files: [file | _]} do
      event = DocsPublisher.build_file_event(file)

      # Required envelope fields
      assert Map.has_key?(event, :event_id)
      assert Map.has_key?(event, :event)
      assert Map.has_key?(event, :schema_version)
      assert Map.has_key?(event, :timestamp)
      assert Map.has_key?(event, :source)
      assert Map.has_key?(event, :source_node)
      assert Map.has_key?(event, :payload)

      # Validate values
      assert is_binary(event.event_id)
      assert is_binary(event.event)
      assert is_binary(event.schema_version)
      assert is_binary(event.timestamp)
      assert event.source == "github_bot"
    end

    test "batch event has required envelope fields", %{index: index} do
      event = DocsPublisher.build_batch_complete_event(index)

      # Required envelope fields
      assert Map.has_key?(event, :event_id)
      assert Map.has_key?(event, :event)
      assert Map.has_key?(event, :schema_version)
      assert Map.has_key?(event, :timestamp)
      assert Map.has_key?(event, :source)
      assert Map.has_key?(event, :source_node)
      assert Map.has_key?(event, :payload)

      # Validate values
      assert is_binary(event.event_id)
      assert event.event == "docs.indexed.batch"
      assert event.source == "github_bot"
    end

    test "events are JSON serializable", %{files: [file | _]} do
      event = DocsPublisher.build_file_event(file)

      assert {:ok, _json} = Jason.encode(event)
    end

    test "batch events are JSON serializable", %{index: index} do
      event = DocsPublisher.build_batch_complete_event(index)

      assert {:ok, _json} = Jason.encode(event)
    end
  end

  describe "edge cases" do
    test "generates unique event IDs", %{files: [file | _]} do
      event1 = DocsPublisher.build_file_event(file)
      event2 = DocsPublisher.build_file_event(file)

      assert event1.event_id != event2.event_id
    end

    test "handles special characters in file paths", %{index: index} do
      [first_file | _] = Map.values(index.files)

      file_with_special_chars = %{
        first_file
        | path: "path/with spaces & special-chars.ex"
      }

      event = DocsPublisher.build_file_event(file_with_special_chars)

      assert event.payload.path == "path/with spaces & special-chars.ex"
      assert {:ok, _json} = Jason.encode(event)
    end

    test "handles large keyword lists", %{index: index} do
      [first_file | _] = Map.values(index.files)

      file_with_many_keywords = %{
        first_file
        | keywords: Enum.map(1..100, &"keyword_#{&1}")
      }

      event = DocsPublisher.build_file_event(file_with_many_keywords)

      assert length(event.payload.keywords) == 100
      assert {:ok, _json} = Jason.encode(event)
    end

    test "triggered_by option is included", %{files: [file | _]} do
      event =
        DocsPublisher.build_file_event(file, triggered_by: "custom_trigger")

      assert event.triggered_by == "custom_trigger"
    end
  end
end
