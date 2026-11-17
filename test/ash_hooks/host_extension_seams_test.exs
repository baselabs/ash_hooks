defmodule AshHooks.HostExtensionSeamsTest do
  use ExUnit.Case, async: false
  require Ash.Query
  @moduletag capture_log: true
  alias AshHooks.{Ingress, PrimaryKey}
  alias AshHooks.Http.Bounded
  alias AshHooks.Delivery, as: Runtime
  alias AshHooks.Endpoint, as: EndpointAPI
  alias AshHooks.Provider.VerifiedFacts

  def repo,
    do:
      if(System.get_env("ASH_HOOKS_POSTGRES") == "1",
        do: AshHooks.TestPostgres.Repo,
        else: AshHooks.Test.RegistryRepo
      )

  def custodian,
    do:
      if(System.get_env("ASH_HOOKS_POSTGRES") == "1",
        do: AshHooks.TestPostgres.Custodian,
        else: AshHooks.Test.Custodian
      )

  def current_key, do: {:ok, "current-verification-key"}
  def previous_key, do: {:ok, "previous-verification-key"}

  def upstream_resolver(conn, counter, proof) do
    1 = :atomics.add_get(counter, 1, 1)
    {:ok, %{source: :events, tenant: "tenant-a", host_context: proof, connection: conn}}
  end

  def allow_destination(_, _), do: :allow
  def worker_headers(_, _, _), do: %{"x-before" => "value"}

  def key_list, do: {:ok, "rotation-list"}

  defmodule FactsProvider do
    use AshHooks.Provider, verify: [algorithm: :hmac_sha256, signature: {:header, "x-signature"}]
    @impl true
    def verify_signature(body, context, keys) do
      keys =
        if keys == "rotation-list",
          do: ["current-verification-key", "previous-verification-key"],
          else: keys

      case context[:host_context] do
        %{digest: digest, tenant: tenant, key_ref: ref, policy: :events} = proof ->
          if digest == :crypto.hash(:sha256, body) and tenant == context.tenant and
               ref == key_ref(keys) and proof[:accepted] == true do
            {:ok, %{"key_ref" => ref, "upstream" => true}}
          else
            {:error, :invalid_signature}
          end

        {:provider_failure, :raise} ->
          raise "provider-private-value"

        {:provider_failure, :throw} ->
          throw("provider-private-value")

        {:provider_failure, :exit} ->
          exit("provider-private-value")

        {:provider_failure, :malformed} ->
          :invalid_result

        nil ->
          case super(body, context, keys) do
            :ok ->
              AshHooks.Provider.Signature.verification_result([
                {:error, :invalid_signature},
                {:ok, %{"key_ref" => key_ref(keys), "upstream" => false}}
              ])

            error ->
              error
          end

        _ ->
          {:error, :invalid_signature}
      end
    end

    defp key_ref(%AshHooks.Custody.Key{ref: ref}), do: ref
    defp key_ref(keys) when is_list(keys), do: "rotation-list"
    defp key_ref(key), do: key

    @impl true
    def event_identity(%{"id" => id}), do: {:ok, id}
    def event_identity(_), do: {:error, :malformed_payload}
    @impl true
    def parse_event_type(_), do: {:ok, :event}
    @impl true
    def handle_event(_, _, context) do
      send(Application.fetch_env!(:ash_hooks, :host_extension_owner), {:handled, context})
      {:ok, :handled}
    end
  end

  defmodule InvalidFactsProvider do
    use AshHooks.Provider, verify: [algorithm: :hmac_sha256, signature: {:header, "x-signature"}]
    @impl true
    def verify_signature(_, _, _), do: {:ok, %{private: "must not persist"}}
  end

  defmodule MalformedFactsProvider do
    use AshHooks.Provider

    @impl true
    def verify_signature(body, context, keys),
      do: AshHooks.HostExtensionSeamsTest.FactsProvider.verify_signature(body, context, keys)

    @impl true
    def event_identity(_), do: {:ok, "authenticated-malformed"}

    @impl true
    def parse_event_type(_), do: {:ok, :event}

    @impl true
    def handle_event(_, _), do: raise("malformed receipts must never reach the handler")
  end

  defmodule Signer do
    @behaviour AshHooks.Signer
    alias AshHooks.HostExtensionSeamsTest, as: Test

    @impl true
    def sign(request, context) do
      send(
        Application.fetch_env!(:ash_hooks, :host_extension_owner),
        {:signing, request, context, Test.repo().in_transaction?()}
      )

      case context.endpoint.signer_behavior do
        :skip ->
          :skip

        :terminal ->
          {:error, :terminal}

        :retry ->
          {:error, :retry}

        :raise ->
          raise "callback-private-value"

        :throw ->
          throw("callback-private-value")

        :exit ->
          exit("callback-private-value")

        :bad_result ->
          {:private, "callback-private-value"}

        :empty_headers ->
          {:ok, [], %{key_refs: ["host-key"]}}

        :empty_refs ->
          {:ok, [{"signature", "x"}], %{key_refs: []}}

        :non_list_refs ->
          {:ok, [{"signature", "x"}], %{key_refs: nil}}

        :bad_refs ->
          {:ok, [{"signature", "x"}], %{key_refs: [String.duplicate("x", 256)]}}

        :many_refs ->
          {:ok, [{"signature", "x"}], %{key_refs: List.duplicate("x", 9)}}

        :collision ->
          {:ok, [{"X-Before", "private"}], %{key_refs: ["host-key"]}}

        :reserved_te ->
          {:ok, [{"Te", "trailers"}], %{key_refs: ["host-key"]}}

        :reserved_transfer ->
          {:ok, [{"transfer-encoding", "chunked"}], %{key_refs: ["host-key"]}}

        :invalid_header ->
          {:ok, [{"signature", "\r\n"}], %{key_refs: ["host-key"]}}

        :slow ->
          Process.sleep(2_000)
          {:error, :retry}

        :good ->
          sign_request(request, context)
      end
    end

    defp sign_request(request, context) do
      tenant = context.custody_tenant || context.tenant
      ref = context.endpoint.host_signing_key_ref

      case Test.custodian().sign(
             ref,
             tenant,
             {:legacy_hmac, :sha256},
             Test.signature_input(request)
           ) do
        {:ok, mac} -> {:ok, [{"signature", Base.encode64(mac)}], %{key_refs: [ref]}}
        {:error, :tenant_mismatch} -> {:error, :terminal}
        _ -> {:error, :retry}
      end
    end
  end

  defmodule HostConfig do
    use Ash.Resource, data_layer: :embedded

    attributes do
      attribute :algorithm, :atom,
        constraints: [one_of: [:hmac]],
        allow_nil?: false,
        public?: true
    end

    actions do
      defaults [:read, create: :*, update: :*]
    end
  end

  defmodule Endpoint do
    use AshHooks.Test.HostExtensionResource,
      table: "host_seam_endpoints",
      extensions: [AshHooks.Endpoint]

    actions do
      defaults [:read, :create, :update]
      default_accept :*
    end

    attributes do
      attribute :host_signing_key_ref, :string, public?: true
      attribute :host_signing_scheme, :atom, default: :hmac, public?: true
      attribute :host_uuid, :uuid, public?: true
      attribute :host_config, AshHooks.HostExtensionSeamsTest.HostConfig, public?: true
      attribute :signer_behavior, :atom, default: :good, public?: true
    end

    endpoint do
      signer AshHooks.HostExtensionSeamsTest.Signer

      signer_attributes [
        :host_signing_key_ref,
        :host_signing_scheme,
        :host_uuid,
        :host_config,
        :signer_behavior
      ]

      native_signing :optional
      key_lifecycle :on
      legacy_key_lifecycle :on
    end
  end

  defmodule PlainEndpoint do
    use AshHooks.Test.HostExtensionResource,
      table: "host_seam_plain_endpoints",
      extensions: [AshHooks.Endpoint]

    actions do
      defaults [:read, :create, :update]
      default_accept :*
    end
  end

  defmodule PlainAttempt do
    use AshHooks.Test.HostExtensionResource,
      table: "host_seam_plain_attempts",
      extensions: [AshHooks.OutboundAttempt]

    actions do
      defaults [:read]
    end
  end

  defmodule Registry do
    use AshHooks.Test.HostExtensionResource,
      table: "host_seam_registry",
      extensions: [AshHooks.KeyRegistry]
  end

  defmodule CustodyEndpoint do
    use AshHooks.Test.HostExtensionResource,
      table: "host_seam_custody_endpoints",
      extensions: [AshHooks.Endpoint]

    actions do
      defaults [:read, :create, :update]
      default_accept :*
    end

    attributes do
      attribute :host_signing_key_ref, :string, public?: true
      attribute :signer_behavior, :atom, default: :good, public?: true
    end

    endpoint do
      signer AshHooks.HostExtensionSeamsTest.Signer
      signer_attributes [:host_signing_key_ref, :signer_behavior]
      native_signing :optional
      key_lifecycle :on
      legacy_key_lifecycle :on

      custodian if System.get_env("ASH_HOOKS_POSTGRES") == "1",
                  do: AshHooks.TestPostgres.Custodian,
                  else: AshHooks.Test.Custodian

      key_registry AshHooks.HostExtensionSeamsTest.Registry
    end
  end

  defmodule Delivery do
    use AshHooks.Test.HostExtensionResource,
      table: "host_seam_deliveries",
      extensions: [AshHooks.OutboundDelivery]

    actions do
      defaults [:read]
    end

    attributes do
      timestamps()
    end

    outbound_delivery do
      resend_tracking :on
      test_tracking :on
    end
  end

  defmodule Attempt do
    use AshHooks.Test.HostExtensionResource,
      table: "host_seam_attempts",
      extensions: [AshHooks.OutboundAttempt]

    actions do
      defaults [:read]
    end

    outbound_attempt do
      record_signing_provenance :on
    end
  end

  defmodule EventLog do
    use AshHooks.Test.HostExtensionResource,
      table: "host_seam_events",
      extensions: [AshHooks.OutboundEvent]

    actions do
      defaults [:read]
    end

    attributes do
      timestamps()
    end
  end

  defmodule Subscription do
    use AshHooks.Test.HostExtensionResource,
      table: "host_seam_subscriptions",
      extensions: [AshHooks.Subscription]

    actions do
      defaults [:create]
      default_accept :*

      read :read do
        primary? true

        pagination do
          required? true
          offset? true
          default_limit 1
        end
      end
    end

    subscription do
      endpoint_resource AshHooks.HostExtensionSeamsTest.Endpoint
    end
  end

  defmodule Emitter do
    use AshHooks.Test.HostExtensionResource, table: "host_seam_emitters", extensions: [AshHooks]

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :create]
    end

    webhooks do
      outbound :event do
        subscriptions AshHooks.HostExtensionSeamsTest.Subscription
        deliveries AshHooks.HostExtensionSeamsTest.Delivery
        events AshHooks.HostExtensionSeamsTest.EventLog
      end
    end
  end

  defmodule Ledger do
    use AshHooks.Test.HostExtensionResource,
      table: "host_seam_ledger",
      extensions: [AshHooks, AshHooks.InboundDelivery]

    actions do
      defaults [:read]
    end

    inbound_delivery do
      record_verified_facts :on
      record_provider_alias :on
    end

    webhooks do
      inbound :events do
        provider AshHooks.HostExtensionSeamsTest.FactsProvider
        secret {AshHooks.HostExtensionSeamsTest, :current_key, []}
        previous_secret {AshHooks.HostExtensionSeamsTest, :previous_key, []}
      end

      inbound :key_list do
        provider AshHooks.HostExtensionSeamsTest.FactsProvider
        secret {AshHooks.HostExtensionSeamsTest, :key_list, []}
      end

      inbound :invalid do
        provider AshHooks.HostExtensionSeamsTest.InvalidFactsProvider
        secret {AshHooks.HostExtensionSeamsTest, :current_key, []}
      end

      inbound :malformed do
        provider AshHooks.HostExtensionSeamsTest.MalformedFactsProvider
        secret {AshHooks.HostExtensionSeamsTest, :current_key, []}
      end

      inbound :source do
        source_record AshHooks.HostExtensionSeamsTest.Source
      end
    end
  end

  defmodule LedgerOff do
    use AshHooks.Test.HostExtensionResource,
      table: "host_seam_ledger_off",
      extensions: [AshHooks, AshHooks.InboundDelivery]

    actions do
      defaults [:read]
    end

    webhooks do
      inbound :events do
        provider AshHooks.HostExtensionSeamsTest.FactsProvider
        secret {AshHooks.HostExtensionSeamsTest, :current_key, []}
      end

      inbound :invalid do
        provider AshHooks.HostExtensionSeamsTest.InvalidFactsProvider
        secret {AshHooks.HostExtensionSeamsTest, :current_key, []}
      end
    end
  end

  defmodule Source do
    use AshHooks.Test.HostExtensionResource,
      table: "host_seam_sources",
      extensions: [AshHooks.InboundSource]

    actions do
      defaults [:read, :create, :update]
      default_accept :*
    end

    inbound_source do
      ledger AshHooks.HostExtensionSeamsTest.Ledger
      providers facts: AshHooks.HostExtensionSeamsTest.FactsProvider

      custodian if System.get_env("ASH_HOOKS_POSTGRES") == "1",
                  do: AshHooks.TestPostgres.Custodian,
                  else: AshHooks.Test.Custodian

      key_registry AshHooks.HostExtensionSeamsTest.Registry
    end
  end

  if Code.ensure_loaded?(Oban.Worker) do
    defmodule Worker do
      use AshHooks.Worker,
        deliveries: AshHooks.HostExtensionSeamsTest.Delivery,
        endpoints: AshHooks.HostExtensionSeamsTest.Endpoint,
        attempts: AshHooks.HostExtensionSeamsTest.Attempt,
        destination_policy: {AshHooks.HostExtensionSeamsTest, :allow_destination},
        delivery_headers: {AshHooks.HostExtensionSeamsTest, :worker_headers},
        http_opts: [validate_destination: false]
    end
  end

  defmodule Domain do
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource AshHooks.HostExtensionSeamsTest.PlainEndpoint
      resource AshHooks.HostExtensionSeamsTest.PlainAttempt
      resource AshHooks.HostExtensionSeamsTest.Endpoint
      resource AshHooks.HostExtensionSeamsTest.CustodyEndpoint
      resource AshHooks.HostExtensionSeamsTest.Registry
      resource AshHooks.HostExtensionSeamsTest.Delivery
      resource AshHooks.HostExtensionSeamsTest.Attempt
      resource AshHooks.HostExtensionSeamsTest.EventLog
      resource AshHooks.HostExtensionSeamsTest.Subscription
      resource AshHooks.HostExtensionSeamsTest.Emitter
      resource AshHooks.HostExtensionSeamsTest.Ledger
      resource AshHooks.HostExtensionSeamsTest.LedgerOff
      resource AshHooks.HostExtensionSeamsTest.Source
    end
  end

  @resources [
    PlainEndpoint,
    PlainAttempt,
    Endpoint,
    CustodyEndpoint,
    Registry,
    Delivery,
    Attempt,
    EventLog,
    Subscription,
    Emitter,
    Ledger,
    LedgerOff,
    Source
  ]

  setup_all do
    if System.get_env("ASH_HOOKS_POSTGRES") != "1" do
      previous = Application.get_env(:ash_hooks, AshHooks.Test.RegistryRepo)

      Application.put_env(
        :ash_hooks,
        AshHooks.Test.RegistryRepo,
        Application.fetch_env!(:ash_hooks, AshHooks.Test.Repo)
      )

      {:ok, pid} = AshHooks.Test.RegistryRepo.start_link()
      Process.unlink(pid)

      on_exit(fn ->
        Supervisor.stop(pid)

        if previous,
          do: Application.put_env(:ash_hooks, AshHooks.Test.RegistryRepo, previous),
          else: Application.delete_env(:ash_hooks, AshHooks.Test.RegistryRepo)
      end)
    end

    for resource <- @resources, do: create_table(resource)
    custodian().setup_store!()

    on_exit(fn ->
      custodian().drop_store!()
      for resource <- Enum.reverse(@resources), do: repo().query!("DROP TABLE #{table(resource)}")
    end)

    :ok
  end

  setup do
    for resource <- @resources, do: repo().query!("DELETE FROM #{table(resource)}")
    repo().query!("DELETE FROM custody_conformance_keys")
    previous = Application.get_env(:ash_hooks, :host_extension_owner)
    Application.put_env(:ash_hooks, :host_extension_owner, self())

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ash_hooks, :host_extension_owner, previous),
        else: Application.delete_env(:ash_hooks, :host_extension_owner)
    end)

    :ok
  end

  test "facts validation admits bounded JSON and refuses all invalid shapes" do
    assert VerifiedFacts.valid?(%{
             "s" => "text",
             "n" => 1,
             "f" => 1.5,
             "b" => true,
             "z" => nil,
             "l" => [%{"x" => false}]
           })

    assert VerifiedFacts.valid?(%{"x" => String.duplicate("x", 8_184)})
    refute VerifiedFacts.valid?(%{"x" => String.duplicate("x", 8_185)})

    for invalid <- [
          nil,
          [],
          %{atom: "value"},
          %{"x" => :atom},
          %{"x" => self()},
          %{"x" => <<255>>},
          ~D[2026-11-17],
          %{"x" => [1 | 2]}
        ] do
      refute VerifiedFacts.valid?(invalid)
    end

    nested = Enum.reduce(1..9, "value", fn _, value -> %{"x" => value} end)
    refute VerifiedFacts.valid?(nested)
  end

  test "winning current, previous and scheme rotation-list facts reach the row and handler" do
    for {source, key, expected} <- [
          {:events, "current-verification-key", "current-verification-key"},
          {:events, "previous-verification-key", "previous-verification-key"},
          {:key_list, "previous-verification-key", "rotation-list"}
        ] do
      body = Jason.encode!(%{"id" => unique()})
      assert {:ok, :created, row} = Ingress.ingest(Ledger, source, body, context(body, key))
      assert row.verified_facts["key_ref"] == expected
      assert_receive {:handled, %{verified_facts: facts, tenant: "tenant-a"} = delivered}
      assert facts == row.verified_facts
      refute inspect(delivered) =~ expected
    end
  end

  test "first authenticated receipt keeps facts through duplicates and recovery" do
    body = Jason.encode!(%{"id" => unique()})

    assert {:ok, :created, row} =
             Ingress.ingest(Ledger, :events, body, context(body, "current-verification-key"))

    assert_receive {:handled, _}

    assert {:ok, :duplicate, duplicate} =
             Ingress.ingest(Ledger, :events, body, context(body, "previous-verification-key"))

    assert duplicate.verified_facts == row.verified_facts
    expired = DateTime.add(DateTime.utc_now(), -60, :second)
    update_machine(row, %{status: :claimed, lease_expires_at: expired})
    assert {:ok, 1} = Ingress.reap(Ledger, tenant: "tenant-a")
    assert_receive {:handled, %{verified_facts: facts}}
    assert facts == row.verified_facts
  end

  test "recording off admits facts without widening the schema and malformed facts fail closed" do
    refute Ash.Resource.Info.attribute(LedgerOff, :verified_facts)
    assert Ash.Resource.Info.attribute(Ledger, :verified_facts).sensitive?
    body = Jason.encode!(%{"id" => unique()})

    assert {:ok, :created, row} =
             Ingress.ingest(LedgerOff, :events, body, context(body, "current-verification-key"))

    refute Map.has_key?(row, :verified_facts)
    assert_receive {:handled, %{verified_facts: nil}}

    assert {:error, %AshHooks.Errors.Unknown.UnknownError{}} =
             Ingress.ingest(Ledger, :invalid, body, context(body, "current-verification-key"))

    assert [] = Ash.read!(Ledger, tenant: "tenant-a", authorize?: false)

    assert {:error, %AshHooks.Errors.Unknown.UnknownError{}} =
             Ingress.ingest(LedgerOff, :invalid, body, context(body, "current-verification-key"))
  end

  test "provider exceptions and malformed verdicts fail closed before persisting any receipt" do
    assert {:ok, _} =
             AshHooks.InboundSource.create_source(Source, %{source: :source, provider: :facts},
               material: "source-key",
               kind: {:sender_hmac, :sha256},
               tenant: "tenant-a"
             )

    for source <- [:events, :source], behavior <- [:raise, :throw, :exit, :malformed] do
      body = Jason.encode!(%{"id" => unique()})

      ctx =
        body
        |> context("current-verification-key")
        |> Map.put(:host_context, {:provider_failure, behavior})

      assert {:error, %AshHooks.Errors.Unknown.UnknownError{} = error} =
               Ingress.ingest(Ledger, source, body, ctx)

      refute inspect(error) =~ "provider-private-value"
    end

    assert [] = Ash.read!(Ledger, tenant: "tenant-a", authorize?: false)
    refute_receive {:handled, _}
  end

  test "an authenticated malformed receipt retains facts without claiming or handling" do
    body = "{malformed"

    signature =
      :crypto.mac(:hmac, :sha256, "current-verification-key", body) |> Base.encode16(case: :lower)

    ctx = context(body, "current-verification-key") |> Map.put(:signature, signature)
    assert {:ok, :created, row} = Ingress.ingest(Ledger, :malformed, body, ctx)
    assert row.status == :failed_permanent
    assert row.error_class == "malformed_payload"
    assert row.attempts == 0
    assert row.fencing_token == 0
    assert row.verified_facts["key_ref"] == "current-verification-key"
    refute_receive {:handled, _}
  end

  test "redaction clears the sensitive facts under the receipt fence" do
    env = %{
      name: :events,
      provider: FactsProvider,
      external_event_id: unique(),
      type_string: "event",
      payload: %{"personal" => "sender"},
      digest: "digest",
      scope: %{},
      tenant: "tenant-a",
      verified_facts: %{"principal" => "sender"}
    }

    assert {:ok, true, row} = Ingress.ingest_delivery(Ledger, env)
    assert {:ok, token, _} = Ingress.claim_delivery(Ledger, row.id, tenant: "tenant-a")

    assert :ok =
             Ingress.redact_payload(Ledger, row.id, token, fn _ -> %{} end, tenant: "tenant-a")

    assert Ash.get!(Ledger, row.id, tenant: "tenant-a", authorize?: false).verified_facts == nil
  end

  test "upstream proof is consumed once and the provider binds body, tenant and source key" do
    body = Jason.encode!(%{"id" => unique()})

    proof = %{
      accepted: true,
      digest: :crypto.hash(:sha256, body),
      tenant: "tenant-a",
      policy: :events,
      key_ref: "current-verification-key"
    }

    counter = :atomics.new(1, [])

    conn =
      Plug.Test.conn(:post, "/webhook", body)
      |> AshHooks.BodyReader.put_raw_body(body)

    options =
      AshHooks.Plug.init(
        resource: Ledger,
        resolve: {__MODULE__, :upstream_resolver, [counter, proof]}
      )

    assert %{status: 200} = AshHooks.Plug.call(conn, options)
    assert :atomics.get(counter, 1) == 1
    ctx = context(body, "current-verification-key") |> Map.put(:host_context, proof)
    assert {:ok, :duplicate, row} = Ingress.ingest(Ledger, :events, body, ctx)
    assert row.verified_facts["upstream"]

    for invalid <- [
          %{proof | digest: <<0>>},
          %{proof | tenant: "tenant-b"},
          %{proof | key_ref: "other"},
          %{proof | policy: :other},
          %{proof | accepted: false}
        ] do
      assert {:error, _} = Ingress.ingest(Ledger, :events, body, %{ctx | host_context: invalid})
    end

    refute Map.has_key?(row, :host_context)
  end

  test "source current, overlap and refreshed keys preserve the winning facts" do
    {:ok, source} =
      AshHooks.InboundSource.create_source(Source, %{source: :source, provider: :facts},
        material: "source-first-key",
        kind: {:sender_hmac, :sha256},
        tenant: "tenant-a"
      )

    {:ok, stale} = Ingress.resolve_source(Ledger, :source, tenant: "tenant-a")

    {:ok, rotated} =
      AshHooks.InboundSource.roll_secret(source,
        material: "source-second-key",
        kind: {:sender_hmac, :sha256},
        tenant: "tenant-a",
        overlap_seconds: 60
      )

    for {key, ref} <- [
          {"source-first-key", source.secret_ref},
          {"source-second-key", rotated.secret_ref}
        ] do
      body = Jason.encode!(%{"id" => unique()})
      assert {:ok, :created, row} = Ingress.ingest(Ledger, :source, body, context(body, key))
      assert row.verified_facts["key_ref"] == ref
    end

    {:ok, _} = AshHooks.InboundSource.expire_previous_secret(rotated, tenant: "tenant-a")
    :ok = custodian().destroy(source.secret_ref, "tenant-a")
    body = Jason.encode!(%{"id" => unique()})
    ctx = context(body, "source-second-key") |> Map.put(:resolved_source, stale)
    assert {:ok, :created, refreshed} = Ingress.ingest(Ledger, :source, body, ctx)
    assert refreshed.verified_facts["key_ref"] == rotated.secret_ref
  end

  test "host-only creation makes no native issue and package actions round-trip custody modes" do
    endpoint = endpoint!(CustodyEndpoint)
    assert endpoint.secret_ref == nil
    assert [] = Ash.read!(Registry, tenant: "tenant-a", authorize?: false)

    {:ok, native, disclosure} =
      EndpointAPI.enable_native_signing(endpoint,
        generate: {:standard_webhooks, :v1},
        tenant: "tenant-a"
      )

    assert is_binary(disclosure)
    assert native.secret_kind == {:standard_webhooks, :v1}

    assert [%{state: :attached, ref: ref}] =
             Ash.read!(Registry, tenant: "tenant-a", authorize?: false)

    assert ref == native.secret_ref
    {:ok, host_only} = EndpointAPI.disable_native_signing(native, tenant: "tenant-a")
    assert host_only.secret_ref == nil
    assert host_only.secret_kind == nil

    assert [%{state: :retired, ref: ^ref}] =
             Ash.read!(Registry, tenant: "tenant-a", authorize?: false)

    {:ok, counts} = AshHooks.KeyRegistry.sweep(Registry, tenant: "tenant-a")
    assert counts.destroyed == 1

    assert {:error, :unknown_ref} =
             custodian().sign(ref, "tenant-a", {:standard_webhooks, :v1}, "body")

    {:ok, native_again, _} =
      EndpointAPI.enable_native_signing(host_only,
        generate: {:standard_webhooks, :v1},
        tenant: "tenant-a"
      )

    refute native_again.secret_ref == ref

    assert {:error, :native_key_exists} =
             EndpointAPI.enable_native_signing(native_again,
               generate: {:standard_webhooks, :v1},
               tenant: "tenant-a"
             )

    assert {:error, _} =
             Ash.update(native_again, %{secret_ref: nil}, tenant: "tenant-a", authorize?: false)
  end

  test "native mode transitions refuse required resources, missing custody and stale owners" do
    required =
      Ash.create!(
        PlainEndpoint,
        %{url: "https://hooks.example.test/hook", secret_ref: "standard-current"},
        tenant: "tenant-a",
        authorize?: false
      )

    assert {:error, :native_signing_required} =
             EndpointAPI.enable_native_signing(required, tenant: "tenant-a")

    assert {:error, :native_signing_required} =
             EndpointAPI.disable_native_signing(required, tenant: "tenant-a")

    no_custody = endpoint!(Endpoint)

    assert {:error, :custody_required} =
             EndpointAPI.enable_native_signing(no_custody, tenant: "tenant-a")

    assert {:error, :custody_required} =
             EndpointAPI.disable_native_signing(no_custody, tenant: "tenant-a")

    host_only = endpoint!(CustodyEndpoint)

    {:ok, native, _} =
      EndpointAPI.enable_native_signing(host_only,
        generate: {:standard_webhooks, :v1},
        tenant: "tenant-a"
      )

    assert {:error, :rolled_underneath} =
             EndpointAPI.disable_native_signing(host_only, tenant: "tenant-a")

    assert Ash.get!(CustodyEndpoint, native.id, tenant: "tenant-a", authorize?: false).secret_ref ==
             native.secret_ref

    assert [%{state: :attached}] = Ash.read!(Registry, tenant: "tenant-a", authorize?: false)
  end

  test "disabling native signing rolls back the owner when its registry key cannot retire" do
    endpoint = endpoint!(CustodyEndpoint)

    assert {:ok, native, _} =
             EndpointAPI.enable_native_signing(endpoint,
               generate: {:standard_webhooks, :v1},
               tenant: "tenant-a"
             )

    assert :ok =
             AshHooks.KeyRegistry.Transitions.retire(
               CustodyEndpoint,
               native.secret_ref,
               DateTime.utc_now(),
               tenant: "tenant-a"
             )

    assert {:error, :key_not_attached} =
             EndpointAPI.disable_native_signing(native, tenant: "tenant-a")

    stored = Ash.get!(CustodyEndpoint, native.id, tenant: "tenant-a", authorize?: false)
    assert stored.secret_ref == native.secret_ref
    assert stored.secret_kind == native.secret_kind
  end

  test "host signing sees the complete request and tenant outside database phases" do
    {listener, url} = listener()
    endpoint = endpoint!(CustodyEndpoint, %{url: url})
    row = delivery!(endpoint)
    receiver = receive_async(listener)
    assert :ok = Runtime.run(args(row, CustodyEndpoint), config(CustodyEndpoint))
    assert_receive {:signing, request, context, false}
    assert context.delivery.event_uuid == row.event_uuid
    assert context.endpoint.id == endpoint.id
    assert context.attempt == 1
    assert context.event_id == row.event_uuid
    assert context.tenant == "tenant-a"
    assert context.custody_tenant == "tenant-a"
    assert request.target == "/a%2Fb?x=%2F"
    assert request.body == "雪"
    assert {"x-before", "value"} in request.headers
    assert {"content-length", "3"} in request.headers
    refute List.keymember?(request.headers, "webhook-signature", 0)
    received = Task.await(receiver)

    assert received ==
             signature_input(%{
               request
               | headers:
                   request.headers ++
                     [{"signature", signature(request, endpoint.host_signing_key_ref)}]
             })

    attempt = only_attempt(row)
    assert attempt.signing_key_refs == [endpoint.host_signing_key_ref]
    assert attempt.signing_key_ref == endpoint.host_signing_key_ref
    assert attempt.outcome == :succeeded
  end

  test "native and host signatures compose and provenance includes only the selected native mode" do
    for mode <- [:standard, :legacy, :dual] do
      {listener, url} = listener()

      endpoint =
        endpoint!(Endpoint, %{
          url: url,
          secret_ref: "standard-current",
          previous_secret_ref: "standard-previous",
          legacy_secret_ref: "legacy-current",
          legacy_previous_secret_ref: "legacy-previous"
        })

      row = delivery!(endpoint, signing_mode: mode)
      receiver = receive_async(listener)
      assert :ok = Runtime.run(args(row), config())
      assert_receive {:signing, request, _, false}

      if mode in [:standard, :dual],
        do: assert(List.keymember?(request.headers, "webhook-signature", 0))

      if mode in [:legacy, :dual],
        do: assert(List.keymember?(request.headers, "x-webhook-signature", 0))

      assert Task.await(receiver) =~ "\r\nsignature: "

      native =
        case mode do
          :standard -> ["standard-current", "standard-previous"]
          :legacy -> ["legacy-current", "legacy-previous"]
          :dual -> ["standard-current", "standard-previous", "legacy-current", "legacy-previous"]
        end

      attempt = only_attempt(row)
      assert attempt.signing_key_refs == native ++ [endpoint.host_signing_key_ref]
      assert attempt.signing_key_ref == hd(native)
    end
  end

  test "signer failures never send, stamp native first use, or disclose callback contents" do
    attach_sign_telemetry()

    for behavior <- [
          :terminal,
          :retry,
          :raise,
          :throw,
          :exit,
          :bad_result,
          :empty_headers,
          :empty_refs,
          :bad_refs,
          :non_list_refs,
          :many_refs,
          :collision,
          :reserved_te,
          :reserved_transfer,
          :invalid_header
        ] do
      {listener, url} = listener()

      endpoint =
        endpoint!(Endpoint, %{url: url, secret_ref: "standard-current", signer_behavior: behavior})

      row = delivery!(endpoint)
      result = Runtime.run(args(row), config())

      if behavior == :terminal,
        do: assert(result == :ok),
        else: assert(match?({:snooze, _}, result))

      assert_receive {:signing, _, _, false}
      assert_receive {:sign_telemetry, %{duration: duration}, %{outcome: outcome}}
      assert duration >= 0
      assert outcome in [:terminal, :retry, :callback_failed, :invalid_result]
      refute inspect(outcome) =~ "callback-private-value"
      assert {:error, :timeout} = :gen_tcp.accept(listener, 5)
      live = Ash.get!(Endpoint, endpoint.id, tenant: "tenant-a", authorize?: false)
      assert live.secret_first_used_at == nil
      persisted = Ash.get!(Delivery, row.id, tenant: "tenant-a", authorize?: false)
      assert persisted.last_error == "signer_failed"
      attempt = only_attempt(row)
      assert attempt.signing_key_refs == nil
      assert attempt.signing_key_ref == nil
      assert attempt.latency_ms == nil
      refute inspect(attempt) =~ "callback-private-value"
    end
  end

  test "skip requires a native signature and a legacy adapter refuses capability before the signer" do
    {listener, url} = listener()
    host_only = endpoint!(Endpoint, %{url: url, signer_behavior: :skip})
    row = delivery!(host_only)
    assert {:snooze, _} = Runtime.run(args(row), config())
    assert_receive {:signing, _, _, false}

    assert Ash.get!(Delivery, row.id, tenant: "tenant-a", authorize?: false).last_error ==
             "unsigned"

    assert {:error, :timeout} = :gen_tcp.accept(listener, 5)

    native =
      endpoint!(Endpoint, %{url: url, signer_behavior: :skip, secret_ref: "standard-current"})

    native_row = delivery!(native)
    receiver = receive_async(listener)
    assert :ok = Runtime.run(args(native_row), config())
    assert_receive {:signing, _, _, false}
    assert Task.await(receiver) =~ "webhook-signature: "
    assert only_attempt(native_row).signing_key_refs == ["standard-current"]

    for adapter <- [AshHooks.Http.Httpc, &AshHooks.Http.Httpc.request/5] do
      refused = delivery!(native)
      assert :ok = Runtime.run(args(refused), config() |> Keyword.put(:http, adapter))
      refute_receive {:signing, _, _, _}
      assert only_attempt(refused).reason == "adapter_cannot_send_prepared"
      assert {:error, :timeout} = :gen_tcp.accept(listener, 5)
    end
  end

  test "signer failures obey the retry ceiling and the common attempt deadline" do
    endpoint = endpoint!(Endpoint, %{signer_behavior: :retry})
    row = delivery!(endpoint)
    assert :ok = Runtime.run(args(row), Keyword.put(config(), :max_attempts, 1))

    assert Ash.get!(Delivery, row.id, tenant: "tenant-a", authorize?: false).status ==
             :dead_letter

    {listener, url} = listener()
    slow = endpoint!(Endpoint, %{url: url, signer_behavior: :slow})
    slow_row = delivery!(slow)
    started = System.monotonic_time(:millisecond)

    assert {:snooze, _} =
             Runtime.run(args(slow_row), config() |> Keyword.put(:attempt_timeout, 500))

    assert System.monotonic_time(:millisecond) - started < 1_500
    slow_id = slow.id
    assert_receive {:signing, _, %{endpoint: %{id: ^slow_id}}, false}
    assert {:error, :timeout} = :gen_tcp.accept(listener, 5)
    assert only_attempt(slow_row).reason == "attempt_timeout"
    assert only_attempt(slow_row).latency_ms == nil

    assert Ash.get!(Delivery, slow_row.id, tenant: "tenant-a", authorize?: false).last_error ==
             "attempt_timeout"
  end

  test "host key resolution cannot borrow an identically named reference from another tenant" do
    endpoint = endpoint!(CustodyEndpoint)

    other =
      Ash.create!(
        CustodyEndpoint,
        %{
          url: endpoint.url,
          host_signing_key_ref: endpoint.host_signing_key_ref
        },
        tenant: "tenant-b",
        authorize?: false
      )

    row = delivery!(other, tenant: "tenant-b")
    result = Runtime.run(args(row, CustodyEndpoint, "tenant-b"), config(CustodyEndpoint))
    assert match?({:snooze, _}, result) or result == :ok
    assert_receive {:signing, _, %{tenant: "tenant-b", custody_tenant: "tenant-b"}, false}
    assert only_attempt(row, "tenant-b").signing_key_refs == nil
    refute Ash.get!(Delivery, row.id, tenant: "tenant-b", authorize?: false).status == :succeeded
  end

  test "transport failure retains the native and host references that really signed" do
    {listener, url} = listener()
    endpoint = endpoint!(Endpoint, %{url: url, legacy_secret_ref: "legacy-current"})
    row = delivery!(endpoint, signing_mode: :legacy)

    receiver =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        _ = read_request(socket, "")
        :gen_tcp.close(socket)
      end)

    assert {:snooze, _} = Runtime.run(args(row), config())
    Task.await(receiver)
    attempt = only_attempt(row)
    assert attempt.signing_key_ref == "legacy-current"
    assert attempt.signing_key_refs == ["legacy-current", endpoint.host_signing_key_ref]
    assert is_integer(attempt.latency_ms)
  end

  test "a host-only 410 disables through NULL filters and records original provenance exactly once" do
    {listener, url} = listener()

    endpoint =
      endpoint!(Endpoint, %{
        url: url,
        host_uuid: Ash.UUID.generate(),
        host_config: %{algorithm: :hmac}
      })

    row = delivery!(endpoint)
    receiver = receive_async(listener, 410)
    assert :ok = Runtime.run(args(row), config())
    Task.await(receiver)
    assert_receive {:signing, _, _, false}

    assert Ash.get!(Endpoint, endpoint.id, tenant: "tenant-a", authorize?: false).status ==
             :disabled

    final = Ash.get!(Delivery, row.id, tenant: "tenant-a", authorize?: false)
    assert final.status == :dead_letter
    snapshot = final.endpoint_snapshot
    assert snapshot["signer_attributes"]["host_uuid"] == endpoint.host_uuid
    assert snapshot["signer_attributes"]["host_config"] == %{"algorithm" => "hmac"}
    assert only_attempt(row).signing_key_refs == [endpoint.host_signing_key_ref]
    update_machine(final, %{status: :disable_pending})
    assert :ok = Runtime.run(args(final), config())
    refute_receive {:signing, _, _, _}
    assert [attempt] = attempts(row)
    assert attempt.signing_key_refs == [endpoint.host_signing_key_ref]
  end

  test "410 recovery compares typed attributes and protects missing and changed signer snapshots" do
    for change <- [
          :same,
          :missing,
          :old_provenance,
          :host_signing_scheme,
          :host_uuid,
          :host_config,
          :host_signing_key_ref
        ] do
      endpoint =
        endpoint!(Endpoint, %{host_uuid: Ash.UUID.generate(), host_config: %{algorithm: :hmac}})

      row = delivery!(endpoint)

      fields = [
        :host_signing_key_ref,
        :host_signing_scheme,
        :host_uuid,
        :host_config,
        :signer_behavior
      ]

      attrs =
        Map.new(fields, fn field ->
          definition = Ash.Resource.Info.attribute(Endpoint, field)

          {:ok, value} =
            Ash.Type.dump_to_embedded(
              definition.type,
              Map.get(endpoint, field),
              definition.constraints
            )

          {Atom.to_string(field), value}
        end)

      attrs = if change == :missing, do: Map.delete(attrs, "host_uuid"), else: attrs

      snapshot =
        %{
          "endpoint_pk" => PrimaryKey.encode(endpoint),
          "url" => endpoint.url,
          "secret_ref" => nil,
          "previous_secret_ref" => nil,
          "legacy_secret_ref" => nil,
          "legacy_previous_secret_ref" => nil,
          "status_attribute" => "status",
          "status_value" => "enabled",
          "signer_attributes" => attrs,
          "attempt_history" => %{
            "signing_key_ref" => "original-host-ref",
            "signing_key_refs" => ["original-host-ref"],
            "latency_ms" => 1
          }
        }
        |> Jason.encode!()
        |> Jason.decode!()

      snapshot =
        if change == :old_provenance,
          do: update_in(snapshot["attempt_history"], &Map.delete(&1, "signing_key_refs")),
          else: snapshot

      case change do
        :host_signing_scheme ->
          Ash.update!(endpoint, %{host_signing_scheme: :other},
            tenant: "tenant-a",
            authorize?: false
          )

        :host_uuid ->
          Ash.update!(endpoint, %{host_uuid: Ash.UUID.generate()},
            tenant: "tenant-a",
            authorize?: false
          )

        :host_config ->
          Ash.update!(endpoint, %{host_config: nil}, tenant: "tenant-a", authorize?: false)

        :host_signing_key_ref ->
          Ash.update!(endpoint, %{host_signing_key_ref: "new-host-ref"},
            tenant: "tenant-a",
            authorize?: false
          )

        _ ->
          :ok
      end

      update_machine(row, %{
        status: :disable_pending,
        attempts: 1,
        response_status: 410,
        endpoint_snapshot: snapshot
      })

      assert :ok = Runtime.run(args(row), config())
      refute_receive {:signing, _, _, _}
      expected = if change in [:same, :old_provenance], do: :disabled, else: :enabled

      assert Ash.get!(Endpoint, endpoint.id, tenant: "tenant-a", authorize?: false).status ==
               expected

      expected_refs = if change == :old_provenance, do: nil, else: ["original-host-ref"]
      assert only_attempt(row).signing_key_refs == expected_refs
    end
  end

  test "test sends, resends, and delivery replay use the same signer context" do
    {listener, url} = listener()
    endpoint = endpoint!(Endpoint, %{url: url})
    receiver = receive_async(listener)
    opts = config() |> Keyword.merge(type: :event, tenant: "tenant-a")
    assert {:ok, %{status: :succeeded, delivery: row}} = Runtime.test_send(endpoint, opts)
    Task.await(receiver)
    assert_receive {:signing, _, %{event_id: event_id, attempt: 1}, false}
    assert event_id == row.event_uuid

    assert {:ok, %{delivery: resent}} =
             Runtime.resend(row, endpoints: Endpoint, requested_by: "test", tenant: "tenant-a")

    receiver = receive_async(listener)
    assert :ok = Runtime.run(args(resent), config())
    Task.await(receiver)
    assert_receive {:signing, _, %{event_id: ^event_id, attempt: 2}, false}

    assert {:ok, %{resent: 1}} =
             Runtime.replay(Delivery,
               endpoints: Endpoint,
               requested_by: "test",
               tenant: "tenant-a",
               status: [:succeeded]
             )

    receiver = receive_async(listener)
    assert :ok = Runtime.run(args(resent), config())
    Task.await(receiver)
    assert_receive {:signing, _, %{event_id: ^event_id, attempt: 3}, false}
  end

  test "event-log replay inherits the tenant-matching legacy subscription" do
    {listener, url} = listener()
    endpoint = endpoint!(Endpoint, %{url: url, legacy_secret_ref: "legacy-current"})

    subscription =
      Ash.create!(
        Subscription,
        %{endpoint_id: endpoint.id, event_types: ["event"], signing_mode: :legacy},
        tenant: "tenant-a",
        authorize?: false
      )

    event_id = Ash.UUID.generate()

    Ash.create!(EventLog, %{event_uuid: event_id, event_type: "event", payload: "雪"},
      action: :record,
      tenant: "tenant-a",
      authorize?: false
    )

    assert {:ok, %{created: 1}} =
             AshHooks.OutboundEvent.replay(EventLog, endpoint,
               deliveries: Delivery,
               endpoints: Endpoint,
               requested_by: "test",
               declaration: {Emitter, :event},
               tenant: "tenant-a",
               event_uuid: event_id
             )

    [row] = Ash.read!(Delivery, tenant: "tenant-a", authorize?: false)
    assert row.signing_mode == :legacy
    assert row.subscription_id == subscription.id
    receiver = receive_async(listener)
    assert :ok = Runtime.run(args(row), config())
    Task.await(receiver)
    assert_receive {:signing, request, %{event_id: ^event_id}, false}
    assert List.keymember?(request.headers, "x-webhook-signature", 0)
    refute List.keymember?(request.headers, "webhook-signature", 0)
    assert only_attempt(row).signing_key_ref == "legacy-current"
  end

  test "replay resolves matching modes within the tenant and refuses conflicting subscriptions" do
    for {modes, expected} <- [
          {[], :standard},
          {[nil], :standard},
          {[:legacy, :legacy], :legacy},
          {[:legacy, :standard], :conflict}
        ] do
      endpoint = endpoint!(Endpoint)

      for mode <- modes do
        Ash.create!(
          Subscription,
          %{endpoint_id: endpoint.id, event_types: ["*"], signing_mode: mode},
          tenant: "tenant-a",
          authorize?: false
        )
      end

      Ash.create!(
        Subscription,
        %{endpoint_id: endpoint.id, event_types: ["event"], signing_mode: :dual},
        tenant: "tenant-b",
        authorize?: false
      )

      event_id = unique()

      Ash.create!(EventLog, %{event_uuid: event_id, event_type: "event", payload: "bytes"},
        action: :record,
        tenant: "tenant-a",
        authorize?: false
      )

      assert {:ok, counts} =
               AshHooks.OutboundEvent.replay(EventLog, endpoint,
                 deliveries: Delivery,
                 endpoints: Endpoint,
                 requested_by: "test",
                 declaration: {Emitter, :event},
                 tenant: "tenant-a",
                 event_uuid: event_id
               )

      rows =
        Delivery
        |> Ash.Query.filter(event_uuid == ^event_id)
        |> Ash.read!(tenant: "tenant-a", authorize?: false)

      if expected == :conflict do
        assert counts.skipped == 1
        assert rows == []
      else
        assert counts.created == 1
        assert [%{signing_mode: ^expected}] = rows
      end
    end
  end

  test "generated worker signs under the same deadline and tenant context" do
    if Code.ensure_loaded?(Oban.Worker) do
      {listener, url} = listener()
      endpoint = endpoint!(Endpoint, %{url: url})
      row = delivery!(endpoint)
      worker = AshHooks.HostExtensionSeamsTest.Worker
      route = AshHooks.OutboundBinding.named_route(worker, :enqueue)
      {:ok, bound} = AshHooks.Worker.bind_route(row, route, "tenant-a")
      receiver = receive_async(listener)
      assert :ok = apply(worker, :perform, [%Oban.Job{args: args(bound)}])
      Task.await(receiver)

      assert_receive {:signing, request, %{tenant: "tenant-a", event_id: event_id, attempt: 1},
                      false}

      assert event_id == row.event_uuid
      assert {"x-before", "value"} in request.headers
    end
  end

  test "legacy map adapters and functions work with unchanged schemas and native wire signatures" do
    for adapter <- [AshHooks.Http.Httpc, &AshHooks.Http.Httpc.request/5] do
      {listener, url} = listener()

      endpoint =
        Ash.create!(
          PlainEndpoint,
          %{url: url, secret_ref: "standard-current"},
          tenant: "tenant-a",
          authorize?: false
        )

      row = delivery!(endpoint)
      receiver = receive_async(listener)

      opts =
        config(PlainEndpoint)
        |> Keyword.put(:http, adapter)
        |> Keyword.put(:attempts, PlainAttempt)

      assert :ok = Runtime.run(args(row, PlainEndpoint), opts)
      wire = Task.await(receiver)
      assert wire =~ "webhook-signature: "
      assert String.ends_with?(wire, "雪")
      refute_receive {:signing, _, _, _}
      [attempt] = Ash.read!(PlainAttempt, tenant: "tenant-a", authorize?: false)
      assert attempt.signing_key_ref == "standard-current"
      refute Map.has_key?(attempt, :signing_key_refs)
      repo().query!("DELETE FROM #{table(PlainAttempt)}")
    end
  end

  test "optional native mode signs a previous-only slot and stamps its actual use" do
    for {slot, mode, header, ref} <- [
          {:previous_secret_ref, :standard, "webhook-signature", "standard-previous"},
          {:legacy_previous_secret_ref, :legacy, "x-webhook-signature", "legacy-previous"}
        ] do
      {listener, url} = listener()

      endpoint =
        endpoint!(Endpoint, Map.merge(%{url: url, signer_behavior: :skip}, %{slot => ref}))

      row = delivery!(endpoint, signing_mode: mode)
      receiver = receive_async(listener)
      assert :ok = Runtime.run(args(row), config())
      assert_receive {:signing, request, _, false}
      assert List.keymember?(request.headers, header, 0)
      Task.await(receiver)
      assert only_attempt(row).signing_key_refs == [ref]

      stamp =
        if slot == :previous_secret_ref,
          do: :previous_secret_first_used_at,
          else: :legacy_previous_secret_first_used_at

      assert Map.get(
               Ash.get!(Endpoint, endpoint.id, tenant: "tenant-a", authorize?: false),
               stamp
             )
    end
  end

  defp unique, do: Ash.UUID.generate()

  defp context(body, key) do
    signature = :crypto.mac(:hmac, :sha256, key, body) |> Base.encode16(case: :lower)
    %{tenant: "tenant-a", headers: [{"x-signature", signature}]}
  end

  defp endpoint!(resource, attrs \\ %{}) do
    ref = "host-" <> unique()
    :ok = custodian().store(ref, "host-signing-material", "tenant-a", {:legacy_hmac, :sha256})

    # Match RealReceiver: hostname registration passes the production URL type,
    # and the runtime options explicitly permit the controlled local receiver.
    Ash.create!(
      resource,
      Map.merge(%{url: "http://localhost:9/a%2Fb?x=%2F", host_signing_key_ref: ref}, attrs),
      tenant: "tenant-a",
      authorize?: false
    )
  end

  defp delivery!(endpoint, opts \\ []) do
    Ash.create!(
      Delivery,
      %{
        event_uuid: unique(),
        event_type: "event",
        payload: "雪",
        endpoint_id: endpoint.id,
        signing_mode: opts[:signing_mode]
      },
      action: :dispatch,
      tenant: opts[:tenant] || "tenant-a",
      authorize?: false
    )
  end

  defp args(row, endpoint_resource \\ Endpoint, tenant \\ "tenant-a") do
    %{
      "endpoint_id" => row.endpoint_id,
      "event_uuid" => row.event_uuid,
      "delivery_pk" => PrimaryKey.encode(row),
      "delivery_resource" => Atom.to_string(Delivery),
      "endpoint_resource" => Atom.to_string(endpoint_resource),
      "dispatch_source" => row.dispatch_source,
      "dispatch_route" => row.dispatch_route,
      "tenant" => tenant
    }
  end

  defp config(endpoints \\ Endpoint) do
    [
      deliveries: Delivery,
      endpoints: endpoints,
      attempts: Attempt,
      http: Bounded,
      http_opts: [validate_destination: false],
      ssrf_check: fn _ -> true end,
      delivery_headers: %{"x-before" => "value"},
      secret_resolver: fn ref ->
        {:ok,
         if(String.starts_with?(ref, "standard"),
           do: "whsec_" <> Base.encode64(String.duplicate("k", 32)),
           else: "legacy-signing-material"
         )}
      end
    ]
  end

  def signature_input(request) do
    IO.iodata_to_binary([
      request.method,
      " ",
      request.target,
      " HTTP/1.1\r\n",
      Enum.map(request.headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "\r\n",
      request.body
    ])
  end

  defp signature(request, ref) do
    {:ok, bytes} =
      custodian().sign(ref, "tenant-a", {:legacy_hmac, :sha256}, signature_input(request))

    Base.encode64(bytes)
  end

  defp attempts(row, tenant \\ "tenant-a") do
    Attempt
    |> Ash.Query.filter(event_uuid == ^row.event_uuid)
    |> Ash.read!(tenant: tenant, authorize?: false)
  end

  defp only_attempt(row, tenant \\ "tenant-a") do
    [attempt] = attempts(row, tenant)
    attempt
  end

  defp attach_sign_telemetry do
    id = {__MODULE__, self()}

    :ok =
      :telemetry.attach(
        id,
        [:ash_hooks, :delivery, :sign],
        fn _, measurements, metadata, pid ->
          send(pid, {:sign_telemetry, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp listener do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, port} = :inet.port(socket)
    on_exit(fn -> :gen_tcp.close(socket) end)
    {socket, "http://localhost:#{port}/a%2Fb?x=%2F"}
  end

  defp receive_async(listener, status \\ 204) do
    Task.async(fn ->
      {:ok, socket} = :gen_tcp.accept(listener, 5_000)

      try do
        request = read_request(socket, "")

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 #{status} Result\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
          )

        request
      after
        :gen_tcp.close(socket)
      end
    end)
  end

  defp read_request(socket, bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [head, body] ->
        [_, length] = Regex.run(~r/\r\ncontent-length: (\d+)/i, head)
        if byte_size(body) == String.to_integer(length), do: bytes, else: read_more(socket, bytes)

      _ ->
        read_more(socket, bytes)
    end
  end

  defp read_more(socket, bytes) do
    {:ok, more} = :gen_tcp.recv(socket, 0, 5_000)
    read_request(socket, bytes <> more)
  end

  defp table(resource) do
    section = if System.get_env("ASH_HOOKS_POSTGRES") == "1", do: :postgres, else: :sqlite
    Spark.Dsl.Extension.get_opt(resource, [section], :table)
  end

  defp create_table(resource) do
    primary = Ash.Resource.Info.primary_key(resource)
    attributes = Ash.Resource.Info.attributes(resource)
    additions = Enum.filter(attributes, &(&1.name in [:verified_facts, :signing_key_refs]))
    baseline = Enum.reject(attributes, &(&1.name in [:verified_facts, :signing_key_refs]))
    optional? = Spark.Dsl.Extension.get_opt(resource, [:endpoint], :native_signing) == :optional

    original =
      Enum.map(baseline, fn attr ->
        if optional? and attr.name == :secret_ref, do: %{attr | allow_nil?: false}, else: attr
      end)

    create = fn name, fields ->
      columns =
        Enum.map(fields, fn attr ->
          "#{attr.name} #{sql_type(Ash.Type.storage_type(attr.type, attr.constraints))}" <>
            if(attr.allow_nil?, do: "", else: " NOT NULL")
        end)

      repo().query!(
        "CREATE TABLE #{name} (#{Enum.join(columns, ", ")}, PRIMARY KEY (#{Enum.join(primary, ", ")}))"
      )
    end

    create.(table(resource), original)

    for attr <- additions do
      type = sql_type(Ash.Type.storage_type(attr.type, attr.constraints))
      repo().query!("ALTER TABLE #{table(resource)} ADD COLUMN #{attr.name} #{type}")
    end

    if optional? do
      if System.get_env("ASH_HOOKS_POSTGRES") == "1" do
        repo().query!("ALTER TABLE #{table(resource)} ALTER COLUMN secret_ref DROP NOT NULL")
      else
        prior = table(resource) <> "_before_optional"
        repo().query!("ALTER TABLE #{table(resource)} RENAME TO #{prior}")
        create.(table(resource), attributes)
        repo().query!("INSERT INTO #{table(resource)} SELECT * FROM #{prior}")
        repo().query!("DROP TABLE #{prior}")
      end
    end

    for identity <- Ash.Resource.Info.identities(resource) do
      fields = Enum.uniq([:tenant_id | identity.keys])

      repo().query!(
        "CREATE UNIQUE INDEX #{table(resource)}_#{identity.name}_index ON #{table(resource)} (#{Enum.join(fields, ", ")})"
      )
    end
  end

  defp sql_type(type) do
    postgres? = System.get_env("ASH_HOOKS_POSTGRES") == "1"

    case type do
      {:array, item} ->
        if(postgres?, do: sql_type(item) <> "[]", else: "TEXT")

      :uuid ->
        if(postgres?, do: "UUID", else: "TEXT")

      :binary_id ->
        if(postgres?, do: "UUID", else: "TEXT")

      :binary ->
        if(postgres?, do: "BYTEA", else: "BLOB")

      :boolean ->
        if(postgres?, do: "BOOLEAN", else: "INTEGER")

      :integer ->
        "BIGINT"

      :float ->
        "DOUBLE PRECISION"

      :decimal ->
        "NUMERIC"

      :map ->
        if(postgres?, do: "JSONB", else: "TEXT")

      datetime when datetime in [:utc_datetime, :utc_datetime_usec] ->
        if(postgres?, do: "TIMESTAMPTZ", else: "TEXT")

      _ ->
        "TEXT"
    end
  end

  defp update_machine(row, fields) do
    postgres? = System.get_env("ASH_HOOKS_POSTGRES") == "1"
    fields = Enum.to_list(fields)

    values =
      Enum.map(fields, fn {name, value} ->
        attr = Ash.Resource.Info.attribute(row.__struct__, name)
        {:ok, dumped} = Ash.Type.dump_to_native(attr.type, value, attr.constraints)

        cond do
          not postgres? and is_struct(dumped, DateTime) -> DateTime.to_iso8601(dumped)
          not postgres? and is_map(dumped) -> Jason.encode!(dumped)
          true -> dumped
        end
      end)

    assignments =
      fields
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {{name, _}, index} ->
        "#{name} = " <> if(postgres?, do: "$#{index}", else: "?")
      end)

    key = if postgres?, do: "$#{length(fields) + 1}::text::uuid", else: "?"

    repo().query!(
      "UPDATE #{table(row.__struct__)} SET #{assignments} WHERE id = #{key}",
      values ++ [row.id]
    )
  end
end
