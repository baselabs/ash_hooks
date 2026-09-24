defmodule AshHooks.Verifiers.MultitenancyNoBypass do
  @moduledoc false
  # The single-resource half of the tenancy contract (D3): a resource that
  # declares multitenancy must not mark ANY action `multitenancy
  # :bypass`/`:bypass_all` — a bypassed action reads or writes globally
  # beside the tenant-scoped machine primitives, exactly the hole the
  # per-call cross-resource consistency check closes BETWEEN resources.
  #
  # Scope note (probed 2026-09-24): the design text names the
  # package-INJECTED actions, but a consumer cannot redeclare one — Ash's
  # RequireUniqueActionNames rejects the duplicate before any verifier
  # runs (OBSERVED: "Multiple actions (2) with the name `disable`"), and
  # the transformers inject them without a multitenancy option. That exact
  # case is unreachable, so the guard generalizes to every action on a
  # multitenant package resource — which includes the injected set by
  # definition, and catches the reachable shape: a consumer's OWN action
  # flipping ledger rows across tenants. `:allow_global` rides the guard
  # too: it is the per-action twin of the resource-level `global?: true`
  # the package rejects outright (Ash's read path applies the tenant
  # filter but skips the tenant requirement under it).
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  def verify(dsl_state) do
    if Verifier.get_option(dsl_state, [:multitenancy], :strategy) do
      dsl_state
      |> Verifier.get_entities([:actions])
      |> Enum.filter(&bypassed?/1)
      |> case do
        [] ->
          :ok

        bypassed ->
          raise Spark.Error.DslError,
            module: Verifier.get_persisted(dsl_state, :module),
            path: [:actions, hd(bypassed).name],
            message:
              "a multitenant resource must not mark actions " <>
                "`multitenancy :bypass` or `:allow_global` — they read and write " <>
                "globally beside tenant-scoped ones (the tenancy contract, ADR-0011): " <>
                inspect(Enum.map(bypassed, & &1.name))
      end
    else
      :ok
    end
  end

  # Map.get, never struct access: the GENERIC action entity carries no
  # :multitenancy key at all (Ash's own reads of the field use Map.get for
  # the same reason — cross-vendor finding, both peers).
  defp bypassed?(action), do: Map.get(action, :multitenancy) in [:bypass, :bypass_all, :allow_global]
end
