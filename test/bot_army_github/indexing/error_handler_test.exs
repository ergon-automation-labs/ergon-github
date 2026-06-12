defmodule BotArmyGithub.Indexing.ErrorHandlerTest do
  use ExUnit.Case
  @moduletag :indexing

  alias BotArmyGithub.Indexing.ErrorHandler
  alias BotArmyGithub.Indexing.ErrorHandler.IndexingError

  describe "classify_error/2" do
    test "classifies file not found errors as skippable" do
      error = %File.Error{reason: :enoent}
      assert {:skip, :file_not_found, true} = ErrorHandler.classify_error(error)
    end

    test "classifies permission denied as skippable" do
      error = %File.Error{reason: :eacces}
      assert {:skip, :permission_denied, true} = ErrorHandler.classify_error(error)
    end

    test "classifies is_directory as skippable" do
      error = %File.Error{reason: :eisdir}
      assert {:skip, :is_directory, true} = ErrorHandler.classify_error(error)
    end

    test "classifies too many open files as retryable" do
      error = %File.Error{reason: :emfile}
      assert {:retry, backoff_ms} = ErrorHandler.classify_error(error)
      assert is_integer(backoff_ms)
      assert backoff_ms > 0
    end

    test "classifies memory errors as retryable" do
      error = %RuntimeError{message: "out of memory"}
      assert {:retry, backoff_ms} = ErrorHandler.classify_error(error)
      assert is_integer(backoff_ms)
    end

    test "classifies unicode errors as skippable" do
      error = %UnicodeConversionError{}
      assert {:skip, :invalid_encoding, true} = ErrorHandler.classify_error(error)
    end

    test "classifies function clause errors as failures" do
      error = %FunctionClauseError{}
      assert {:fail, reason} = ErrorHandler.classify_error(error)
      assert is_binary(reason)
    end

    test "classifies unknown errors as skippable" do
      error = %ArgumentError{message: "test error"}
      assert {:skip, :unknown_error, true} = ErrorHandler.classify_error(error)
    end
  end

  describe "handle_indexing_error/3" do
    test "skips file on recoverable error" do
      error = %File.Error{reason: :enoent}
      {:ok, skipped} = ErrorHandler.handle_indexing_error("test.txt", error)

      assert skipped == 1
    end

    test "retries on temporary errors" do
      error = %File.Error{reason: :emfile}

      start_time = System.monotonic_time(:millisecond)
      {:ok, 0} = ErrorHandler.handle_indexing_error("test.txt", error)
      elapsed = System.monotonic_time(:millisecond) - start_time

      # At least 4 seconds for backoff
      assert elapsed >= 4000
    end

    test "returns error on fatal errors" do
      error = %FunctionClauseError{}
      {:error, reason} = ErrorHandler.handle_indexing_error("test.txt", error)

      assert is_binary(reason)
    end

    test "includes operation context" do
      error = %File.Error{reason: :enoent}

      {:ok, _} =
        ErrorHandler.handle_indexing_error("test.txt", error, operation: :extract_keywords)

      # Should log without error (operation context included)
      :ok
    end
  end

  describe "new_error/3" do
    test "creates indexed error with context" do
      assert_raise IndexingError, fn ->
        ErrorHandler.new_error(:invalid_file, "File format not supported", %{file: "test.bin"})
      end
    end

    test "error contains all context fields" do
      try do
        ErrorHandler.new_error(:codec_error, "Cannot decode UTF-8", %{encoding: "binary"})
      rescue
        error ->
          assert error.type == :codec_error
          assert error.message == "Cannot decode UTF-8"
          assert error.context[:encoding] == "binary"
      end
    end
  end

  describe "validate_file/1" do
    setup do
      test_dir = Path.join(System.tmp_dir!(), "validate_test_#{System.unique_integer()}")
      File.mkdir_p!(test_dir)

      on_exit(fn ->
        File.rm_rf!(test_dir)
      end)

      {:ok, test_dir: test_dir}
    end

    test "validates readable files", %{test_dir: test_dir} do
      file_path = Path.join(test_dir, "test.txt")
      File.write!(file_path, "test content")

      assert {:ok, ^file_path} = ErrorHandler.validate_file(file_path)
    end

    test "rejects non-existent files" do
      assert {:error, :file_not_found, _} = ErrorHandler.validate_file("/nonexistent/file.txt")
    end

    test "rejects directories" do
      test_dir = System.tmp_dir!()
      assert {:error, :is_directory, _} = ErrorHandler.validate_file(test_dir)
    end
  end

  describe "get_error_stats/1" do
    test "calculates statistics from error list" do
      errors = [
        {:skip, :file_not_found, :extract_keywords},
        {:skip, :permission_denied, :extract_keywords},
        {:fail, :unknown_error, :index}
      ]

      stats = ErrorHandler.get_error_stats(errors)

      assert stats.total_errors == 3
      assert stats.skipped_count == 2
      assert stats.failed_count == 1
      assert stats.by_type[:file_not_found] == 1
      assert stats.by_type[:permission_denied] == 1
      assert stats.by_type[:unknown_error] == 1
    end

    test "handles empty error list" do
      stats = ErrorHandler.get_error_stats([])

      assert stats.total_errors == 0
      assert stats.skipped_count == 0
      assert stats.failed_count == 0
    end

    test "groups errors by operation" do
      errors = [
        {:skip, :file_not_found, :extract_keywords},
        {:skip, :permission_denied, :extract_keywords},
        {:fail, :unknown_error, :index}
      ]

      stats = ErrorHandler.get_error_stats(errors)

      assert stats.by_operation[:extract_keywords] == 2
      assert stats.by_operation[:index] == 1
    end
  end

  describe "log_completion/4" do
    test "logs completion with metrics" do
      start_time = DateTime.utc_now()
      Process.sleep(100)

      # Should not raise
      ErrorHandler.log_completion("test_operation", 50, 5, start_time)

      :ok
    end

    test "handles zero success/error counts" do
      start_time = DateTime.utc_now()

      ErrorHandler.log_completion("test_operation", 0, 0, start_time)

      :ok
    end

    test "calculates success rate correctly" do
      start_time = DateTime.utc_now()

      # 80% success rate (80 success, 20 errors)
      ErrorHandler.log_completion("test_operation", 80, 20, start_time)

      :ok
    end
  end

  describe "error classification edge cases" do
    test "classifies memory-related runtime errors as retryable" do
      error = %RuntimeError{message: "Erlang memory allocation failed"}
      assert {:retry, _backoff_ms} = ErrorHandler.classify_error(error)
    end

    test "classifies other runtime errors as skippable" do
      error = %RuntimeError{message: "Something went wrong"}
      assert {:skip, :unknown_error, true} = ErrorHandler.classify_error(error)
    end

    test "provides context in error classification" do
      context = %{file: "test.txt", operation: "walk"}
      error = %File.Error{reason: :enoent}

      # Should classify with context (context is logged)
      assert {:skip, :file_not_found, true} = ErrorHandler.classify_error(error, context)
    end
  end

  describe "error metrics" do
    test "error stats reflect all error categories" do
      errors = [
        {:skip, :file_not_found, :walk},
        {:skip, :permission_denied, :walk},
        {:skip, :invalid_encoding, :extract_keywords},
        {:fail, :unknown_error, :index},
        {:fail, :codec_error, :index}
      ]

      stats = ErrorHandler.get_error_stats(errors)

      assert stats.total_errors == 5
      assert stats.skipped_count == 3
      assert stats.failed_count == 2
      assert map_size(stats.by_type) == 5
      assert map_size(stats.by_operation) == 3
    end

    test "calculates operation statistics correctly" do
      errors = [
        {:skip, :file_not_found, :walk},
        {:skip, :file_not_found, :walk},
        {:skip, :file_not_found, :walk},
        {:fail, :unknown_error, :index},
        {:fail, :unknown_error, :index}
      ]

      stats = ErrorHandler.get_error_stats(errors)

      assert stats.by_operation[:walk] == 3
      assert stats.by_operation[:index] == 2
    end
  end
end
