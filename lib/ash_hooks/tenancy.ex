defmodule AshHooks.Tenancy do
  @moduledoc """
  Validates an operation's resource modules against a tenant.

  `resolve/2` takes the resource modules an entry point touches and the tenant:

  * If none declares multitenancy, the tenant passes through unchanged.
  * If all declare attribute multitenancy on the same attribute with
    `global?: false`, a tenant is required. Missing tenants return
    `{:error, :tenant_required}`.
  * Mixed declarations, different tenant attributes, context multitenancy,
    or `global?: true` return `{:error, :tenancy_mismatch}`.

  Entry points supply every resource they read or write, including optional
  event-log and attempt-history resources. They reject missing or mismatched
  tenancy before data access. Event-log replay forwards its tenant to resend
  when rearming an existing terminal delivery.
  """

  alias Ash.Resource.Info

  @typedoc "Errors returned when the supplied resource set or tenant is invalid."
  @type error :: :tenant_required | :tenancy_mismatch

  @doc """
  Resolves the entry family's declaration set against the caller's tenant.

  `modules` is the caller-supplied resource set. Only these modules are
  checked. `tenant` is the caller-supplied tenant, or `nil` when absent.
  """
  @spec resolve([module()], term()) :: {:ok, term()} | {:error, error()}
  def resolve(modules, tenant) do
    declarations = Enum.map(modules, &declaration/1)

    cond do
      Enum.all?(declarations, &is_nil/1) ->
        {:ok, tenant}

      Enum.any?(declarations, &is_nil/1) ->
        {:error, :tenancy_mismatch}

      consistent_attribute_set?(declarations) ->
        require_tenant(tenant)

      true ->
        {:error, :tenancy_mismatch}
    end
  end

  defp require_tenant(nil), do: {:error, :tenant_required}
  defp require_tenant(tenant), do: {:ok, tenant}

  defp consistent_attribute_set?(declarations) do
    attributes = declarations |> Enum.map(& &1.attribute) |> Enum.uniq()

    Enum.all?(declarations, &(&1.strategy == :attribute and not &1.global?)) and
      length(attributes) == 1 and hd(attributes) != nil
  end

  # nil = undeclared (OBSERVED against ash 3.33.10: a resource without a
  # multitenancy block introspects as {nil, nil, nil}; a declared block
  # materializes the schema defaults, global? false when unset). A module
  # that is not a resource at all reads the same way: the pre-flight is a
  # contract check, not a validation; the broken module fails at its own
  # first Ash call, contained, exactly as before the tenancy floor.
  defp declaration(module) do
    if Spark.Dsl.is?(module, Ash.Resource) do
      case Info.multitenancy_strategy(module) do
        nil ->
          nil

        strategy ->
          %{
            strategy: strategy,
            attribute: Info.multitenancy_attribute(module),
            global?: Info.multitenancy_global?(module) == true
          }
      end
    else
      nil
    end
  end
end
