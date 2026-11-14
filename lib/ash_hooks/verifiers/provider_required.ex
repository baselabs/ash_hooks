defmodule AshHooks.Verifiers.ProviderRequired do
  @moduledoc false
  use Spark.Dsl.Verifier
  alias Spark.Dsl.Verifier

  def verify(dsl_state) do
    resource = Verifier.get_persisted(dsl_state, :module)

    dsl_state
    |> Verifier.get_entities([:webhooks])
    |> Enum.filter(&is_struct(&1, AshHooks.Inbound))
    |> Enum.each(fn inbound ->
      if is_nil(inbound.provider) and is_nil(inbound.source_record) do
        raise Spark.Error.DslError,
          module: resource,
          path: [:webhooks, :inbound, inbound.name],
          message:
            "inbound #{inspect(inbound.name)} has no provider. ash_hooks ships no built-in verifiers since 3.0.0: set `provider` to a module that implements AshHooks.Provider, for example one defined with `use AshHooks.Provider, verify: [...]`."
      end

      verify_source(inbound, dsl_state, resource)

      verify_key_material(inbound, resource)
    end)

    :ok
  end

  defp verify_source(inbound, state, resource) do
    cond do
      inbound.source_record &&
          Verifier.get_option(state, [:inbound_delivery], :record_provider_alias, :off) != :on ->
        raise Spark.Error.DslError,
          module: resource,
          path: [:webhooks, :inbound, inbound.name],
          message: "source_record requires inbound_delivery record_provider_alias :on"

      is_nil(inbound.source_record) and is_nil(inbound.secret) ->
        raise Spark.Error.DslError,
          module: resource,
          path: [:webhooks, :inbound, inbound.name],
          message: "inbound requires secret when source_record is absent"

      true ->
        :ok
    end
  end

  defp verify_key_material(inbound, resource) do
    if Application.get_env(:ash_hooks, :key_material) == :custody_only and
         Enum.any?([
           inbound.secret,
           inbound.previous_secret,
           inbound.provider && AshHooks.Provider.byte_secret_callback?(inbound.provider)
         ]) do
      raise Spark.Error.DslError,
        module: resource,
        path: [:webhooks, :inbound, inbound.name],
        message:
          "key_material: :custody_only refuses inbound secret, previous_secret and provider signing-secret callbacks"
    end
  end
end
