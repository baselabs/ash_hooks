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
    |> capture_repos()
  end

  def capture_running do
    Ecto.Repo.all_running()
    |> Enum.flat_map(&running_repo/1)
    |> capture_repos()
  end

  defp running_repo(instance) do
    [Ecto.Adapter.lookup_meta(instance).repo]
  rescue
    # A supervised instance can stop between enumeration and lookup.
    _stopped in [ArgumentError, RuntimeError] -> []
  end

  defp capture_repos(repos) do
    repos
    |> Enum.uniq()
    |> Enum.map(fn repo -> {repo, repo.get_dynamic_repo()} end)
  end

  def capture_child(resources, nil), do: {nil, capture_running() ++ capture(resources)}
  def capture_child(resources, binding), do: {binding, capture(resources)}

  def install_child({binding, repositories}) do
    with :ok <- bind(binding), do: apply(repositories)
  end

  def bind(nil), do: :ok

  def bind({module, name}) do
    case module.bind(name) do
      :ok -> :ok
      _refused -> {:error, :unknown_binding}
    end
  catch
    _, _ -> {:error, :binding_failed}
  end

  def apply(bindings) do
    Enum.each(bindings, fn {repo, instance} -> repo.put_dynamic_repo(instance) end)
  end
end
