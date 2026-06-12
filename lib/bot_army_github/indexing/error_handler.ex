defmodule BotArmyGithub.Indexing.ErrorHandler do
  @moduledoc """
  Error handling and recovery for the GitHub ingestor pipeline.

  Provides:
  - Custom error types for indexing operations
  - Error classification and recovery strategies
  - Error metrics and reporting
  - Graceful degradation and partial success handling
  """

  require Logger

  @doc """
  Custom error types for the indexer.
  """
  defmodule IndexingError do
    defexception [:message, :type, :context]

    def exception(opts) do
      type = Keyword.get(opts, :type, :unknown)
      context = Keyword.get(opts, :context, %{})
      message = Keyword.get(opts, :message, "Indexing error: #{type}")

      %__MODULE__{
        message: message,
        type: type,
        context: context
      }
    end
  end

  @doc """
  Classify an error and determine recovery strategy.

  Returns:
    {:skip, reason, recoverable} - Skip this file/operation
    {:retry, backoff_ms} - Retry after delay
    {:fail, reason} - Cannot recover
  """
  def classify_error(error, context \\ %{}) do
    case error do
      %File.Error{reason: :enoent} ->
        {:skip, :file_not_found, true}

      %File.Error{reason: :eacces} ->
        {:skip, :permission_denied, true}

      %File.Error{reason: :eisdir} ->
        {:skip, :is_directory, true}

      %File.Error{reason: :emfile} ->
        # Too many open files - needs backoff
        {:retry, 5000}

      %RuntimeError{message: msg} ->
        if String.contains?(msg, "memory") do
          {:retry, 10000}
        else
          Logger.warning("Unknown error type", error: inspect(error), context: context)
          {:skip, :unknown_error, true}
        end

      %UnicodeConversionError{} ->
        {:skip, :invalid_encoding, true}

      %FunctionClauseError{} ->
        {:fail, "Invalid operation parameters"}

      error ->
        Logger.warning("Unknown error type", error: inspect(error), context: context)
        {:skip, :unknown_error, true}
    end
  end

  @doc """
  Handle an indexing error with logging and recovery.

  Returns:
    {:ok, skipped_files} - Recovered and continued
    {:error, reason} - Cannot recover
  """
  def handle_indexing_error(file_path, error, opts \\ []) do
    context = %{
      file_path: file_path,
      error_type: error.__struct__,
      error_message: Exception.message(error),
      timestamp: DateTime.utc_now(),
      operation: Keyword.get(opts, :operation, :unknown)
    }

    case classify_error(error, context) do
      {:skip, reason, _recoverable} ->
        Logger.warning("Skipping file due to error",
          reason: reason,
          file: file_path,
          error: inspect(error)
        )

        {:ok, 1}

      {:retry, backoff_ms} ->
        Logger.info("Retrying operation after backoff",
          backoff_ms: backoff_ms,
          file: file_path,
          operation: Keyword.get(opts, :operation)
        )

        Process.sleep(backoff_ms)
        {:ok, 0}

      {:fail, reason} ->
        Logger.error("Fatal error during indexing",
          reason: reason,
          file: file_path,
          error: inspect(error),
          context: context
        )

        {:error, reason}
    end
  end

  @doc """
  Create an indexing error with context.
  """
  def new_error(type, message, context \\ %{}) do
    raise IndexingError,
      type: type,
      message: message,
      context: context
  end

  @doc """
  Validate file before indexing and return detailed error if invalid.
  """
  def validate_file(filepath) do
    cond do
      not File.exists?(filepath) ->
        {:error, :file_not_found, "File does not exist: #{filepath}"}

      File.dir?(filepath) ->
        {:error, :is_directory, "Path is a directory, not a file: #{filepath}"}

      not readable_file?(filepath) ->
        {:error, :not_readable, "File is not readable: #{filepath}"}

      true ->
        {:ok, filepath}
    end
  end

  @doc """
  Get error metrics and statistics.
  """
  def get_error_stats(errors) when is_list(errors) do
    stats = %{
      total_errors: length(errors),
      skipped_count: Enum.count(errors, &(elem(&1, 0) == :skip)),
      failed_count: Enum.count(errors, &(elem(&1, 0) == :fail)),
      by_type: group_errors_by_type(errors),
      by_operation: group_errors_by_operation(errors)
    }

    stats
  end

  @doc """
  Log pipeline completion with error summary.
  """
  def log_completion(operation, success_count, error_count, start_time) do
    duration_ms = DateTime.diff(DateTime.utc_now(), start_time, :millisecond)

    success_rate =
      if success_count + error_count > 0 do
        (success_count / (success_count + error_count) * 100) |> Float.round(1)
      else
        0.0
      end

    rate_per_sec =
      if duration_ms > 0 do
        Float.round(success_count / (duration_ms / 1000), 2)
      else
        0.0
      end

    Logger.info("Indexing operation completed",
      operation: operation,
      successful: success_count,
      errors: error_count,
      success_rate: success_rate,
      duration_ms: duration_ms,
      rate_per_sec: rate_per_sec
    )
  end

  # Private

  defp readable_file?(filepath) do
    case File.stat(filepath) do
      {:ok, stat} -> stat.access == :read_write or stat.access == :read
      {:error, _} -> false
    end
  end

  defp group_errors_by_type(errors) do
    errors
    |> Enum.map(&elem(&1, 1))
    |> Enum.frequencies()
  end

  defp group_errors_by_operation(errors) do
    errors
    |> Enum.map(&elem(&1, 2))
    |> Enum.frequencies()
  end
end
