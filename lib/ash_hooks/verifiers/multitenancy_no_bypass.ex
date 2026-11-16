defmodule AshHooks.Verifiers.MultitenancyNoBypass do
  @moduledoc false
  # Multitenant resources reject :bypass, :bypass_all, and :allow_global actions.
  # This covers both injected and consumer-defined actions.
  # Per-call preflight checks consistency across touched resources.
  # Only attribute tenancy with global?: false passes that preflight.
  # Tenant scoping does not replace application authorization.
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
                "`multitenancy :bypass` or `:allow_global`, which read and write " <>
                "globally beside tenant-scoped ones: " <>
                inspect(Enum.map(bypassed, & &1.name))
      end
    else
      :ok
    end
  end

  # Map.get, never struct access: the GENERIC action entity carries no
  # :multitenancy key at all; Ash's own reads of the field use Map.get
  # for the same reason.
  defp bypassed?(action),
    do: Map.get(action, :multitenancy) in [:bypass, :bypass_all, :allow_global]
end
