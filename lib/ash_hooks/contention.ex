defmodule AshHooks.Contention do
  @moduledoc false

  @deadline_ms 2_000
  @spacing_ms 100
  @jitter_ms 50

  @spec run((-> result)) :: result when result: var
  def run(operation) do
    attempt(operation, System.monotonic_time(:millisecond) + @deadline_ms)
  end

  defp attempt(operation, deadline) do
    result = operation.()
    delay = @spacing_ms + :rand.uniform(@jitter_ms + 1) - 1

    if retryable?(result) and System.monotonic_time(:millisecond) + delay < deadline do
      Process.sleep(delay)

      if System.monotonic_time(:millisecond) < deadline do
        attempt(operation, deadline)
      else
        result
      end
    else
      result
    end
  end

  @spec retryable?(term()) :: boolean()
  def retryable?({:error, error}), do: contention?(error)

  def retryable?(%Ash.BulkResult{status: :error, errors: [_ | _] = errors}),
    do: Enum.all?(errors, &contention?/1)

  def retryable?(_result), do: false

  defp contention?(%Ash.Error.Unknown{errors: [_ | _] = errors}),
    do: Enum.all?(errors, &contention?/1)

  defp contention?(%Ash.Error.Unknown.UnknownError{error: inner}) do
    text = if is_binary(inner), do: inner, else: inspect(inner)
    down = String.downcase(text)

    String.contains?(text, "Exqlite.Error") and
      (String.contains?(down, "database busy") or String.contains?(down, "database is locked"))
  end

  defp contention?(_error), do: false
end
