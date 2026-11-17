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

  test "the deadline preserves the final error without sleeping after the last operation" do
    owner = self()
    first = {:error, busy()}
    final = {:error, busy("database is locked")}
    session = :trace.session_create(__MODULE__, owner, [])

    # The second operation ends 1,950 ms after the first began. The deadline is at most
    # 2,000 ms after that and the spacing is at least 100 ms, so no further sleep fits,
    # however late the scheduler runs this process. It waits with `receive` so that only
    # the retry's own sleeps reach the trace.
    operation = fn ->
      case Process.get(:first_operation_at) do
        nil ->
          Process.put(:first_operation_at, System.monotonic_time(:millisecond))
          first

        began ->
          remaining = max(began + 1_950 - System.monotonic_time(:millisecond), 0)

          receive do
          after
            remaining -> final
          end
      end
    end

    task =
      Task.async(fn ->
        receive do
          :run ->
            result = Contention.run(operation)
            send(owner, {:retry_result, self(), result})

            receive do
              :finish -> result
            end
        end
      end)

    try do
      # Trace patterns match loaded modules only, and test order decides what is loaded.
      Code.ensure_loaded!(Contention)
      Code.ensure_loaded!(Process)
      assert :trace.process(session, task.pid, true, [:call]) == 1
      assert :trace.function(session, {Contention, :attempt, 2}, true, [:local]) == 1
      assert :trace.function(session, {Process, :sleep, 1}, true, []) == 1
      send(task.pid, :run)
      pid = task.pid
      assert_receive {:retry_result, ^pid, ^final}, 5_000
      delivered = :trace.delivered(session, pid)
      assert_receive {:trace_delivered, ^pid, ^delivered}, 5_000
      assert retry_events(pid, []) == [:attempt, :sleep, :attempt]
      send(pid, :finish)
      assert ^final = Task.await(task)
    after
      :trace.session_destroy(session)
      if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
    end
  end

  test "a delayed wakeup never starts another operation after the deadline" do
    owner = self()
    counter = :counters.new(1, [])
    error = {:error, busy()}

    task =
      Task.async(fn ->
        Contention.run(fn ->
          :counters.add(counter, 1, 1)
          send(owner, :attempted)
          error
        end)
      end)

    assert_receive :attempted, 5_000
    :ok = suspend_during_sleep(task.pid, 100)
    attempts = :counters.get(counter, 1)

    try do
      Process.sleep(2_100)
    after
      :erlang.resume_process(task.pid)
    end

    assert ^error = Task.await(task)
    assert :counters.get(counter, 1) == attempts
  end

  defp suspend_during_sleep(_pid, 0), do: flunk("retry never entered its sleep")

  defp suspend_during_sleep(pid, attempts) do
    :erlang.suspend_process(pid)

    if Process.info(pid, :current_function) == {:current_function, {Process, :sleep, 1}} do
      :ok
    else
      :erlang.resume_process(pid)
      Process.sleep(1)
      suspend_during_sleep(pid, attempts - 1)
    end
  end

  defp retry_events(pid, acc) do
    receive do
      {:trace, ^pid, :call, {Contention, :attempt, _}} -> retry_events(pid, [:attempt | acc])
      {:trace, ^pid, :call, {Process, :sleep, [_delay]}} -> retry_events(pid, [:sleep | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
