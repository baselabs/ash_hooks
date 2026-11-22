defmodule AshHooks.Test.PoolReady do
  @moduledoc false

  import ExUnit.Assertions

  # Every connection must finish SQLite initialization before a test takes a
  # writer lock. Holding each checkout at this barrier proves they are distinct.
  def wait(repo) do
    owner = self()
    ref = make_ref()

    tasks =
      for _ <- 1..Keyword.fetch!(repo.config(), :pool_size) do
        Task.async(fn -> hold(repo, owner, ref) end)
      end

    try do
      for _ <- tasks, do: assert_receive({^ref, :ready}, 5_000)
    after
      Enum.each(tasks, &send(&1.pid, ref))
      Enum.each(tasks, &Task.await(&1, 5_000))
    end
  end

  defp hold(repo, owner, ref) do
    repo.checkout(fn ->
      repo.query!("SELECT 1")
      send(owner, {ref, :ready})

      receive do
        ^ref -> :ok
      end
    end)
  end
end
