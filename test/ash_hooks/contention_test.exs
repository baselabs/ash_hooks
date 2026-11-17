defmodule AshHooks.ContentionTest do
  use ExUnit.Case, async: true

  alias Ash.Error.Unknown
  alias Ash.Error.Unknown.UnknownError
  alias AshHooks.Contention

  defp busy(text \\ "database busy"),
    do: %UnknownError{error: "** (Exqlite.Error) " <> text}

  test "recognizes only Exqlite contention, including wrapped and bulk errors" do
    for error <- [busy(), busy("database is locked"), busy("DATABASE BUSY")] do
      assert Contention.retryable?({:error, error})
      assert Contention.retryable?({:error, %Unknown{errors: [error]}})
      assert Contention.retryable?(%Ash.BulkResult{status: :error, errors: [error]})
    end

    assert Contention.retryable?(
             {:error, %UnknownError{error: {:sqlite, "Exqlite.Error: database busy"}}}
           )
  end

  test "every error must be contention and empty errors never qualify" do
    other = %UnknownError{error: "** (Postgrex.Error) database busy"}

    for errors <- [[], [other], [busy(), other], [%Unknown{errors: [busy(), other]}]] do
      refute Contention.retryable?({:error, %Unknown{errors: errors}})
      refute Contention.retryable?(%Ash.BulkResult{status: :error, errors: errors})
    end

    for result <- [
          :ok,
          {:ok, :value},
          {:error, :lease_held},
          {:error, :stale_token},
          {:error, %UnknownError{error: "Exqlite.Error: constraint failed"}},
          {:error, %{message: "database busy"}},
          %Ash.BulkResult{status: :success, errors: [busy()]}
        ] do
      refute Contention.retryable?(result)
      assert Contention.run(fn -> result end) == result
    end
  end

  test "retries a refused write with the documented spacing until success" do
    owner = self()
    counter = :counters.new(1, [])

    assert :ok =
             Contention.run(fn ->
               :counters.add(counter, 1, 1)
               send(owner, {:attempt, System.monotonic_time(:millisecond)})
               if :counters.get(counter, 1) < 3, do: {:error, busy()}, else: :ok
             end)

    assert_receive {:attempt, first}
    assert_receive {:attempt, second}
    assert_receive {:attempt, third}
    assert second - first >= 100
    assert third - second >= 100
    refute_received {:attempt, _}
  end

  test "a monotonic deadline bounds retries and preserves the final error" do
    owner = self()
    error = {:error, busy()}
    started = System.monotonic_time(:millisecond)

    assert ^error =
             Contention.run(fn ->
               send(owner, {:attempt, System.monotonic_time(:millisecond)})
               error
             end)

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 2_000
    assert elapsed < 3_000
    attempts = drain_attempts([])
    assert length(attempts) > 5
    assert Enum.all?(attempts, &(&1 - started < 2_000))
  end

  defp drain_attempts(acc) do
    receive do
      {:attempt, time} -> drain_attempts([time | acc])
    after
      0 -> acc
    end
  end
end
