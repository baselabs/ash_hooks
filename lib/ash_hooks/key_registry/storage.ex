defmodule AshHooks.KeyRegistry.Storage do
  @moduledoc false

  alias Ash.Resource.Info
  alias AshHooks.Errors.Invalid.KeyKindMismatch
  alias Spark.Dsl.Extension

  def section(owner) do
    if Extension.get_opt(owner, [:inbound_source], :ledger), do: :inbound_source, else: :endpoint
  end

  def option(owner, name, default \\ nil),
    do: Extension.get_opt(owner, [section(owner)], name, default)

  def registry(owner), do: option(owner, :key_registry)
  def custodian(owner), do: option(owner, :custodian)

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
      AshHooks.Phase.run([owner, registry], tenant, fn -> phase_result(fun.()) end)
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
