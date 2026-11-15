defmodule AshHooks.InboundSource.Verifiers.Source do
  @moduledoc false
  use Spark.Dsl.Verifier
  alias Ash.Resource.Info
  alias AshHooks.KeyRegistry.Storage
  alias Spark.Dsl.{Extension, Verifier}
  alias Spark.Error.DslError

  def verify(state) do
    ledger = Extension.get_opt(state, [:inbound_source], :ledger)
    registry = Storage.registry(state)
    providers = Extension.get_opt(state, [:inbound_source], :providers)

    with :ok <- verify_ledger(state, ledger),
         :ok <- verify_registry(state, registry) do
      verify_providers(state, providers)
    end
  end

  defp verify_ledger(state, ledger) do
    cond do
      AshHooks.InboundDelivery not in Spark.extensions(ledger) ->
        error(state, "ledger requires AshHooks.InboundDelivery")

      not compatible_tenancy?(state, ledger) ->
        error(
          state,
          "source and ledger tenancy must agree in strategy, attribute name and type, with no global access"
        )

      not scope_matches?(state, ledger) ->
        error(
          state,
          "source scope must match non-nullable ledger scope_identity attributes in name, type and constraints"
        )

      not AshHooks.Custody.tenant_type_supported?(state, AshHooks.Custody.tenant_options(state)) ->
        error(state, "custodian requires custody_tenant_key for this tenant attribute type")

      true ->
        :ok
    end
  end

  defp verify_registry(state, registry) do
    cond do
      AshHooks.KeyRegistry not in Spark.extensions(registry) or
        not Storage.compatible?(registry, state) or not compatible_tenancy?(state, registry) ->
        error(state, "key registry requires compatible transactional storage and tenancy")

      Storage.declaration(registry) != Storage.declaration(state) ->
        error(state, "key registry and source require the same repository for writes")

      true ->
        :ok
    end
  end

  defp verify_providers(state, providers) do
    cond do
      providers == [] or
        length(Keyword.keys(providers)) != length(Enum.uniq(Keyword.keys(providers))) or
          not Enum.all?(providers, fn {name, module} ->
            is_atom(name) and is_atom(module) and not is_nil(module)
          end) ->
        error(state, "providers must be a nonempty allowlist of distinct aliases and modules")

      Application.get_env(:ash_hooks, :key_material) == :custody_only and
          Enum.any?(providers, fn {_, module} ->
            AshHooks.Provider.byte_secret_callback?(module)
          end) ->
        error(state, "key_material: :custody_only refuses provider signing-secret callbacks")

      true ->
        :ok
    end
  end

  defp compatible_tenancy?(source, target) do
    shape(source) == shape(target) and elem(shape(source), 0) in [nil, :attribute] and
      Info.multitenancy_global?(source) != true and Info.multitenancy_global?(target) != true
  end

  defp shape(resource) do
    name = Info.multitenancy_attribute(resource)
    attribute = Info.attribute(resource, name)
    {Info.multitenancy_strategy(resource), name, attribute && attribute.type}
  end

  defp scope_matches?(state, ledger) do
    names = Extension.get_opt(ledger, [:inbound_delivery], :scope_identity, [])
    scope = Extension.get_opt(state, [:inbound_source], :scope, [])

    names == Enum.map(scope, &elem(&1, 0)) and
      Enum.all?(names, fn name ->
        left = Info.attribute(state, name)
        right = Info.attribute(ledger, name)

        left && right && not left.allow_nil? && not right.allow_nil? &&
          left.type == right.type && left.constraints == right.constraints
      end)
  end

  defp error(state, message),
    do:
      {:error,
       DslError.exception(
         module: Verifier.get_persisted(state, :module),
         path: [:inbound_source],
         message: message
       )}
end
