defmodule AshHooks.Verifiers.ProviderJsonDecoder do
  @moduledoc false
  use Spark.Dsl.Verifier

  alias AshHooks.Provider
  alias Spark.Dsl.Verifier

  def verify(dsl_state) do
    # Ingress supplies the default when the option is absent. Keeping absence
    # distinct from an explicit default makes opt-in independent of debug info.
    if Verifier.get_option(dsl_state, [:inbound_delivery], :json_decoder) do
      dsl_state
      |> Verifier.get_entities([:webhooks])
      |> Enum.filter(&is_struct(&1, AshHooks.Inbound))
      |> Enum.each(&verify_provider!(&1, dsl_state))
    end

    :ok
  end

  defp verify_provider!(%{provider: provider, name: name}, dsl_state) do
    Code.ensure_compiled!(provider)

    if function_exported?(provider, :decode_payload, 1) and
         not Provider.generated_callback?(provider, {:decode_payload, 1}) and
         not function_exported?(provider, :decode_payload, 2) do
      raise Spark.Error.DslError,
        module: Verifier.get_persisted(dsl_state, :module),
        path: [:webhooks, :inbound, name],
        message:
          "#{inspect(provider)} defines decode_payload/1; a ledger configuring json_decoder " <>
            "requires decode_payload/2 to decode JSON through the supplied function"
    end
  end
end
