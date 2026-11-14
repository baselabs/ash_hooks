defmodule AshHooks.Endpoint.Verifiers.Custody do
  @moduledoc false
  use Spark.Dsl.Verifier

  alias AshHooks.KeyRegistry.Storage
  alias Spark.Dsl.{Extension, Verifier}
  alias Spark.Error.DslError

  def verify(state) do
    if Extension.get_opt(state, [:endpoint], :custodian) do
      verify_custody(state, Storage.registry(state))
    else
      :ok
    end
  end

  defp verify_custody(state, registry) do
    cond do
      Extension.get_opt(state, [:endpoint], :key_lifecycle, :off) != :on ->
        error(state, "custodian requires key_lifecycle :on")

      is_nil(registry) ->
        error(state, "custodian requires key_registry")

      AshHooks.KeyRegistry not in Spark.extensions(registry) ->
        error(state, "key_registry requires the AshHooks.KeyRegistry extension")

      not Storage.compatible?(registry, state) ->
        error(
          state,
          "custody owners and registries require the same transactional AshPostgres or AshSqlite data layer and tenancy strategy and tenant attribute type"
        )

      true ->
        verify_repo(state, Storage.declaration(registry), Storage.declaration(state))
    end
  end

  defp verify_repo(state, registry, owner)
       when is_atom(registry) and is_atom(owner) and registry != owner,
       do: error(state, "custody owners and registries require the same mutate repo")

  defp verify_repo(_state, _registry, _owner), do: :ok

  defp error(state, message),
    do:
      {:error,
       DslError.exception(
         module: Verifier.get_persisted(state, :module),
         path: [:endpoint, :custodian],
         message: message
       )}
end
