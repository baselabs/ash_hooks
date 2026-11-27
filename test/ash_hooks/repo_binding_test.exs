defmodule AshHooks.RepoBindingTest do
  use ExUnit.Case, async: true

  alias AshHooks.RepoBinding
  alias AshHooks.Test.Repo

  defmodule NoRepo do
    use Ash.Resource, data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key :id
    end
  end

  defmodule Endpoint do
    use Ash.Resource, data_layer: AshSqlite.DataLayer

    sqlite do
      table "repo_binding_endpoints"
      repo(Repo)
    end

    attributes do
      uuid_primary_key :id
    end
  end

  test "captures once per repo, skips resources without one, and applies in a fresh process" do
    assert RepoBinding.capture([NoRepo, nil]) == []
    instance = self()
    previous = Repo.put_dynamic_repo(instance)

    try do
      bindings = RepoBinding.capture([Endpoint, NoRepo, Endpoint])
      assert bindings == [{Repo, instance}]

      task =
        Task.async(fn ->
          assert Repo.get_dynamic_repo() == Repo
          assert :ok = RepoBinding.apply(bindings)
          Repo.get_dynamic_repo()
        end)

      assert Task.await(task) == instance
      assert Repo.get_dynamic_repo() == instance
    after
      Repo.put_dynamic_repo(previous)
    end
  end
end
