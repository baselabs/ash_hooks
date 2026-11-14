defmodule AshHooks.KeyRegistry.Storage do
  @moduledoc false

  alias Ash.Resource.Info
  alias AshHooks.Errors.Invalid.KeyKindMismatch
  alias Spark.Dsl.Extension

  def registry(owner), do: Extension.get_opt(owner, [:endpoint], :key_registry)
  def custodian(owner), do: Extension.get_opt(owner, [:endpoint], :custodian)

  def supported?(resource) do
    Ash.DataLayer.data_layer(resource) in [AshPostgres.DataLayer, AshSqlite.DataLayer] and
      Ash.DataLayer.data_layer_can?(resource, :transact)
  end

  def declaration(resource) do
    section =
      if Ash.DataLayer.data_layer(resource) == AshPostgres.DataLayer, do: :postgres, else: :sqlite

    Extension.get_opt(resource, [section], :repo, nil, true)
  end

  def repo(resource) do
    AshHooks.Phase.repo(resource)
  end

  def compatible?(registry, owner) do
    supported?(registry) and supported?(owner) and
      Ash.DataLayer.data_layer(registry) == Ash.DataLayer.data_layer(owner) and
      tenancy(registry) == tenancy(owner)
  end

  def check(registry, owner) do
    if compatible?(registry, owner) and same_repo?(registry, owner),
      do: :ok,
      else: {:error, KeyKindMismatch.exception([])}
  end

  def same_repo?(registry, owner), do: connection(registry) == connection(owner)

  defp connection(resource) do
    repo = repo(resource)
    {repo, GenServer.whereis(repo.get_dynamic_repo())}
  end

  def phase(registry, owner, tenant, fun) do
    with :ok <- check(registry, owner) do
      AshHooks.Phase.run(owner, tenant, fn -> phase_result(fun.()) end)
    end
  end

  defp phase_result(:ok), do: {:ok, :ok}
  defp phase_result(result), do: result

  def query(resource) do
    AshHooks.Phase.query(resource)
  end

  def owner_query(resource, tenant) do
    resource
    |> query()
    |> Ash.Query.for_read(:read_custody_owner, %{}, authorize?: false, tenant: tenant)
  end

  def context(resource), do: AshHooks.Phase.context(resource)

  defp tenancy(resource) do
    attribute = Info.attribute(resource, Info.multitenancy_attribute(resource))

    {Info.multitenancy_strategy(resource), Info.multitenancy_global?(resource),
     attribute && attribute.type}
  end
end
