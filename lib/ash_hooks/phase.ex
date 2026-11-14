defmodule AshHooks.Phase do
  @moduledoc false

  alias Ash.Error.Unknown.UnknownError

  def run(input, tenant, operation) when is_function(operation, 1) do
    query = Ash.Query.new(input)
    run(query.resource, tenant, fn -> operation.(query(query)) end)
  end

  def run(resources, tenant, operation) when is_function(operation, 0) do
    resources = Enum.filter(List.wrap(resources), &Ash.DataLayer.can?(:transact, &1))

    if resources == [] do
      operation.()
    else
      transact(resources, tenant, operation)
    end
  end

  # The reason of an Ash.transact names no resource, so the repository's
  # transaction-begin callback cannot convert the tenant itself. Every
  # resource in the phase converts the caller's tenant; they must agree.
  defp transact(resources, tenant, operation) do
    joined? = Enum.any?(resources, &Ash.DataLayer.in_transaction?/1)

    with {:ok, key} <- tenant_key(resources, tenant) do
      case Ash.transact(resources, fn -> result(operation.(), joined?) end, tenant: key) do
        {:ok, result} -> unwrap(result, joined?)
        {:error, error} -> {:error, original_error(error)}
      end
    end
  end

  defp tenant_key(resources, tenant) do
    case resources |> Enum.map(&Ash.ToTenant.to_tenant(tenant, &1)) |> Enum.uniq() do
      [key] -> {:ok, key}
      _keys -> {:error, :tenancy_mismatch}
    end
  end

  # Joined reads and refusals must return errors without aborting the host.
  # Write actions retain their own rollback_on_error? and rollback throws.
  defp result(result, true), do: {:ok, result}

  # Ash normalizes rollback reasons to Ash errors. Preserve the package's
  # existing result vocabulary for phases that own their transaction.
  defp result({:error, error}, false),
    do: {:error, UnknownError.exception(field: __MODULE__, value: error)}

  defp result(result, _joined?), do: result

  defp unwrap({:ok, result}, true), do: result
  defp unwrap(result, false), do: result

  defp original_error(%UnknownError{field: __MODULE__, value: error}), do: error
  defp original_error(error), do: error

  def bulk(input, tenant, operation) do
    case run(input, tenant, operation) do
      {:error, error} -> %Ash.BulkResult{status: :error, errors: [error]}
      result -> result
    end
  end

  def query(input) do
    query = Ash.Query.new(input)
    Ash.Query.set_context(query, context(query.resource))
  end

  def context(resource) do
    if Ash.DataLayer.data_layer(resource) in [AshPostgres.DataLayer, AshSqlite.DataLayer] and
         Ash.DataLayer.can?(:transact, resource) do
      %{data_layer: %{repo: repo(resource)}}
    else
      %{}
    end
  end

  def repo(resource) do
    info = Module.concat(Ash.DataLayer.data_layer(resource), :Info)
    info.repo(resource, :mutate)
  end

  def outside_transaction(resource) do
    layer = Ash.DataLayer.data_layer(resource)

    in_transaction? =
      if layer in [AshPostgres.DataLayer, AshSqlite.DataLayer],
        do: Ash.DataLayer.in_transaction?(layer, resource),
        else: Ash.DataLayer.in_transaction?(resource)

    if in_transaction?, do: {:error, :inside_transaction}, else: :ok
  end
end
