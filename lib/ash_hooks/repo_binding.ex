defmodule AshHooks.RepoBinding do
  @moduledoc false

  alias AshHooks.Phase

  def capture(resources) do
    resources
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(
      &(Ash.DataLayer.data_layer(&1) in [AshPostgres.DataLayer, AshSqlite.DataLayer])
    )
    |> Enum.map(&Phase.repo/1)
    |> Enum.uniq()
    |> Enum.map(fn repo -> {repo, repo.get_dynamic_repo()} end)
  end

  def apply(bindings) do
    Enum.each(bindings, fn {repo, instance} -> repo.put_dynamic_repo(instance) end)
  end
end
