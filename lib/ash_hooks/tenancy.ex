defmodule AshHooks.Tenancy do
  @moduledoc """
  The tenancy contract resolver (the tenancy design's D2/D3): every public
  entry family resolves the resources it touches BEFORE any data access.

    * a **single-tenant set** (no resource declares multitenancy) passes
      the tenant through unchanged — inert by construction: Ash applies a
      tenant only when a strategy is declared (reads no-op without one,
      and the data layer ignores tenants except under `:context`), so
      threading `tenant:` unconditionally cannot change single-tenant
      behavior;
    * a **consistent attribute-multitenant set** — every touched resource
      declares `multitenancy :attribute` over the SAME attribute with
      `global?: false` — requires a tenant: none given is the package's
      named `{:error, :tenant_required}` (Ash's own TenantRequired stays
      the backstop on paths this pre-flight cannot see — the bang-path
      heads this guard converts to tuples would otherwise crash);
    * anything else is `{:error, :tenancy_mismatch}` before any data
      access: some-but-not-all declared (an undeclared resource reads
      globally next to tenant-scoped ones), differing attributes, a
      non-`:attribute` strategy (not portable across the package's
      supported data layers), or `global?: true` (which silently
      disables Ash's fail-closed reads — it passes a same-attribute
      consistency check while permitting tenant-less access).

  The cross-tenant hazard the mismatch guard closes is concrete: an
  inconsistent set reached through the delivery runtime would resolve an
  endpoint GLOBALLY under a tenant-scoped row and deliver one tenant's
  payload bytes to another tenant's URL.

  Three `Ash.Resource.Info` introspections per resource per call,
  deliberately uncached: a compile-time cache would race Spark's
  cross-resource compilation.
  """

  alias Ash.Resource.Info

  @typedoc "The named pre-flight errors, returned by every entry family before any data access."
  @type error :: :tenant_required | :tenancy_mismatch

  @doc """
  Resolves the entry family's declaration set against the caller's tenant.

  `modules` are the resources the entry family is about to touch (data
  access through each follows immediately after); `tenant` is the
  caller-supplied tenant, `nil` when none was given.
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
  # materializes the schema defaults — global? false when unset). A module
  # that is not a resource at all reads the same way: the pre-flight is a
  # contract check, not a validation — the broken module fails at its own
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
