defmodule AshHooks.Verifiers.DurableReplay do
  @moduledoc false
  use Spark.Dsl.Verifier

  alias AshHooks.{Inbound, Provider}
  alias Spark.Dsl.{Extension, Verifier}
  alias Spark.Error.DslError

  def verify(state) do
    for %Inbound{} = inbound <- Verifier.get_entities(state, [:webhooks]) do
      case refusal(state, inbound) do
        nil ->
          :ok

        message ->
          raise DslError,
            module: Verifier.get_persisted(state, :module),
            path: [:webhooks, :inbound, inbound.name],
            message: message
      end
    end

    :ok
  end

  defp refusal(_state, %{replay_protection: :legacy, source_binding: nil}), do: nil

  defp refusal(_state, %{replay_protection: mode, source_binding: :authenticated})
       when mode != :durable_identity,
       do: "source_binding :authenticated requires replay_protection :durable_identity"

  defp refusal(state, inbound) do
    if Verifier.get_option(state, [:inbound_delivery], :retain_replay_identities, :off) == :on do
      enabled_refusal(state, inbound)
    else
      "replay_protection requires inbound_delivery retain_replay_identities :on"
    end
  end

  defp enabled_refusal(_state, %{replay_protection: :retired} = inbound),
    do: retired_refusal(inbound)

  defp enabled_refusal(state, inbound) do
    cond do
      Verifier.get_persisted(state, :data_layer) not in [
        AshSqlite.DataLayer,
        AshPostgres.DataLayer
      ] ->
        "durable replay protection requires a SQLite or PostgreSQL ledger with a unique_ingest index"

      not compaction_attributes?(state) ->
        "durable replay protection requires inserted_at and a primary key unaffected by compaction"

      not is_nil(inbound.event_id) or not is_nil(inbound.replay_window_seconds) ->
        "durable replay protection owns the event identity and cannot use a replay window"

      inbound.source_binding != :authenticated ->
        "durable replay protection requires source_binding :authenticated and unique enrolled keys"

      true ->
        enrollment_refusal(state, inbound)
    end
  end

  defp enrollment_refusal(_state, %{source_record: source} = inbound) when not is_nil(source),
    do: source_record_refusal(inbound)

  defp enrollment_refusal(state, inbound) do
    cond do
      Verifier.get_option(state, [:inbound_delivery], :scope_identity, []) != [] ->
        "scoped durable replay routes require a source_record with its own enrolled keys per scope"

      not body_only_mac?(inbound.provider) ->
        "durable replay protection requires a provider with body-only MAC coverage"

      Provider.secret_scope(inbound.provider) != :app_level ->
        "durable replay protection requires declaration or source record keys"

      Verifier.get_option(state, [:multitenancy], :strategy) != nil and
          not tenant_keys?(inbound) ->
        "tenant-scoped durable replay routes require tenant-aware key functions or source records"

      true ->
        handshake_refusal([inbound.provider])
    end
  end

  defp retired_refusal(%{secret: nil, previous_secret: nil}), do: nil
  defp retired_refusal(_inbound), do: "retired declarations cannot configure signing keys"

  defp source_record_refusal(%{
         secret: nil,
         previous_secret: nil,
         source_record: source,
         provider: pinned
       }) do
    Code.ensure_compiled!(source)

    providers =
      source
      |> Extension.get_opt([:inbound_source], :providers, [])
      |> Keyword.values()

    cond do
      pinned && pinned not in providers ->
        "a durable replay source_record provider must be in the source allowlist"

      pinned && not body_only_mac?(pinned) ->
        "a durable replay source_record provider must have body-only MAC coverage"

      is_nil(pinned) and (providers == [] or Enum.any?(providers, &(not body_only_mac?(&1)))) ->
        "a durable replay source_record without a pinned provider requires body-only MAC coverage for every alias"

      true ->
        handshake_refusal(if pinned, do: [pinned], else: providers)
    end
  end

  defp source_record_refusal(_inbound),
    do: "durable replay source_record declarations use only the source record's enrolled keys"

  defp handshake_refusal(providers) do
    case Enum.find(providers, &function_exported?(&1, :handshake, 1)) do
      nil ->
        nil

      provider ->
        "durable replay protection cannot use a provider that implements handshake/1 (#{inspect(provider)})"
    end
  end

  defp body_only_mac?(provider) do
    not is_nil(provider) and Code.ensure_compiled(provider) == {:module, provider} and
      function_exported?(provider, :verify_signature, 3) and Provider.body_only_mac?(provider)
  end

  defp tenant_keys?(inbound) do
    is_function(inbound.secret, 1) and
      (is_nil(inbound.previous_secret) or is_function(inbound.previous_secret, 1))
  end

  defp compaction_attributes?(state) do
    attributes = Verifier.get_entities(state, [:attributes])

    cleared = [
      :payload,
      :external_event_type,
      :verified_facts,
      :provider_alias,
      :error_class,
      :lease_expires_at
    ]

    Enum.any?(attributes, &(&1.name == :inserted_at)) and
      Enum.all?(attributes, &(not &1.primary_key? or &1.name not in [:replay_identity | cleared]))
  end
end
