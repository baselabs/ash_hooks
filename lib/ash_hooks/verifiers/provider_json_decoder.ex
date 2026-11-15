defmodule AshHooks.Verifiers.ProviderJsonDecoder do
  @moduledoc false
  use Spark.Dsl.Verifier

  alias AshHooks.Provider
  alias Spark.Dsl.{Extension, Verifier}

  def verify(dsl_state) do
    # Ingress supplies the default when the option is absent. Keeping absence
    # distinct from an explicit default makes opt-in independent of debug info.
    if Verifier.get_option(dsl_state, [:inbound_delivery], :json_decoder) do
      for %AshHooks.Inbound{} = inbound <- Verifier.get_entities(dsl_state, [:webhooks]),
          provider <- providers(inbound),
          do: verify_provider!(provider, inbound.name, dsl_state)
    end

    :ok
  end

  # A source declaration decodes with whichever allowlisted provider a row's
  # alias selects, so every module in the allowlist reaches this ledger.
  defp providers(%{source_record: nil, provider: provider}), do: [provider]

  defp providers(%{source_record: source}) do
    Code.ensure_compiled!(source)
    source |> Extension.get_opt([:inbound_source], :providers, []) |> Keyword.values()
  end

  defp verify_provider!(provider, name, dsl_state) do
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
