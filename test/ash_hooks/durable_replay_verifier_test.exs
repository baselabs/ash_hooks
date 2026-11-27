defmodule AshHooks.DurableReplayVerifierTest do
  use ExUnit.Case, async: false

  alias AshHooks.Test.{BodyMacHandshakeProvider, Dsl, OtherSourceProvider}

  defmodule ConnectionProvider do
    @moduledoc false
    use AshHooks.Provider, verify: [algorithm: :hmac_sha256, signature: {:header, "x-signature"}]

    @impl true
    def webhook_secret_scope, do: :per_connection
  end

  defmodule IdentityCheckDomain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      allow_unregistered?(true)
    end
  end

  test "a binding requires durable admission" do
    assert_refusal(
      "source_binding :authenticated requires replay_protection :durable_identity",
      replay_protection: :legacy
    )
  end

  test "durable admission requires an opted-in SQL ledger with compaction attributes" do
    for {options, message} <- [
          {[retain: :off], "requires inbound_delivery retain_replay_identities :on"},
          {[storage: :ets], "requires a SQLite or PostgreSQL ledger"},
          {[timestamps?: false],
           "requires inserted_at and a primary key unaffected by compaction"}
        ] do
      assert_refusal(message, options)
    end
  end

  test "durable admission owns identity, binding and key selection" do
    for {options, message} <- [
          {[event_id?: true], "owns the event identity and cannot use a replay window"},
          {[binding: nil], "requires source_binding :authenticated and unique enrolled keys"},
          {[scoped?: true], "requires a source_record with its own enrolled keys per scope"},
          {[provider: AshHooks.CountingProvider],
           "requires a provider with body-only MAC coverage"},
          {[provider: ConnectionProvider], "requires declaration or source record keys"}
        ] do
      assert_refusal(message, options)
    end
  end

  test "context tenancy refuses app-wide signing keys at compile time" do
    assert_refusal(
      "tenant-scoped durable replay routes require tenant-aware key functions or source records",
      storage: :postgres,
      tenancy: :context
    )
  end

  test "a durable declaration refuses a body-only MAC provider with a handshake" do
    assert_refusal("cannot use a provider that implements handshake/1",
      provider: BodyMacHandshakeProvider
    )
  end

  test "retired declarations refuse residual signing keys" do
    assert_refusal("retired declarations cannot configure signing keys",
      replay_protection: :retired,
      binding: nil
    )
  end

  defp assert_refusal(expected, opts) do
    ledger = Module.concat(__MODULE__, "Ledger#{System.unique_integer([:positive])}")

    on_exit(fn ->
      :code.purge(ledger)
      :code.delete(ledger)
    end)

    errors =
      Dsl.errors(fn -> Module.create(ledger, declaration(opts), Macro.Env.location(__ENV__)) end)

    assert [{^ledger, [%Spark.Error.DslError{} = error]}] = errors
    assert error.path == [:webhooks, :inbound, :checked]
    assert error.message =~ expected
  end

  defp declaration(opts) do
    {data_layer, data_layer_options} = storage(Keyword.get(opts, :storage, :sqlite))
    scope = if opts[:scoped?], do: [:account_id], else: []
    timestamps = if Keyword.get(opts, :timestamps?, true), do: quote(do: timestamps())

    binding =
      if name = Keyword.get(opts, :binding, :authenticated),
        do: quote(do: source_binding(unquote(name)))

    extractor = if opts[:event_id?], do: quote(do: event_id(fn _ -> :error end))

    quote do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        data_layer: unquote(data_layer),
        extensions: [AshHooks, AshHooks.InboundDelivery]

      unquote(data_layer_options)
      unquote(tenancy(opts[:tenancy]))

      attributes do
        attribute(:account_id, :string, allow_nil?: false)
        unquote(timestamps)
      end

      actions do
        defaults([:read])
      end

      inbound_delivery do
        retain_replay_identities(unquote(Keyword.get(opts, :retain, :on)))
        scope_identity(unquote(scope))
      end

      webhooks do
        inbound :checked do
          provider(unquote(Keyword.get(opts, :provider, OtherSourceProvider)))
          secret({:app_env, [:durable_replay_fixture_key]})
          replay_protection(unquote(Keyword.get(opts, :replay_protection, :durable_identity)))
          unquote(binding)
          unquote(extractor)
        end
      end
    end
  end

  defp storage(:sqlite) do
    {AshSqlite.DataLayer,
     quote do
       sqlite do
         table("replay_verifier")
         repo(AshHooks.Test.Repo)
       end
     end}
  end

  defp storage(:postgres) do
    {AshPostgres.DataLayer,
     quote do
       postgres do
         table("replay_verifier")
         repo(AshHooks.TestPostgres.Repo)
       end
     end}
  end

  defp storage(:ets) do
    {Ash.DataLayer.Ets,
     quote do
       identities do
         identity :unique_ingest, [:provider, :external_event_id] do
           pre_check_with(IdentityCheckDomain)
         end
       end
     end}
  end

  defp tenancy(:context) do
    quote do
      multitenancy do
        strategy(:context)
      end
    end
  end

  defp tenancy(nil), do: nil
end
