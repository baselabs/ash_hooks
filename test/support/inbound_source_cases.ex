defmodule AshHooks.Test.SourceProvider do
  @moduledoc false
  use AshHooks.Provider,
    verify: [algorithm: :hmac_sha256, signature: {:header, "x-signature"}]

  @compile {:no_warn_undefined, Plug.Conn}
  alias AshHooks.Provider.Signature

  @impl true
  def verify_signature(body, context, %AshHooks.Custody.Key{} = key) do
    digest = if elem(key.kind, 0) == :sender_hmac, do: elem(key.kind, 1), else: :sha256

    with :ok <- Signature.hmac(body, context.headers["x-signature"], key, digest: digest),
         :ok <- check_timestamp(context) do
      if context.headers["x-json-check"] == "required" do
        case Jason.decode(body) do
          {:ok, _} -> :ok
          {:error, _} -> {:error, :malformed_payload}
        end
      else
        :ok
      end
    end
  end

  def verify_signature(body, context, public_key) do
    Signature.ed25519(body, context.headers["x-signature"], public_key)
  end

  defp check_timestamp(context) do
    case context.headers["x-timestamp"] do
      nil -> :ok
      timestamp -> Signature.check_timestamp(timestamp, context, 60)
    end
  end

  @impl true
  def parse_event_type(_payload, context) do
    notify({:parsed, context})
    {:ok, :checked}
  end

  @impl true
  def event_identity(%{"id" => id}, context) do
    notify({:identified, context})
    {:ok, id}
  end

  @impl true
  def handle_event(type, payload, context) do
    notify({:handled, __MODULE__, self(), context})

    if payload["block"], do: Process.sleep(:infinity)

    if payload["retry"],
      do: {:error, :retry, :requested_retry},
      else: {:ok, %AshHooks.Event{type: type, payload: payload}}
  end

  @impl true
  def handshake(%{query_params: %{"challenge" => challenge}}),
    do: {:respond, 200, [], challenge}

  def handshake(_), do: :deliver

  @impl true
  def response({:error, :source_paused}) do
    notify(:paused_response)
    :default
  end

  def response(_), do: :default

  defp notify(message) do
    if sink = Application.get_env(:ash_hooks, :source_test_sink), do: send(sink, message)
  end
end

defmodule AshHooks.Test.OtherSourceProvider do
  @moduledoc false
  use AshHooks.Provider,
    verify: [algorithm: :hmac_sha256, signature: {:header, "x-signature"}]

  @impl true
  def parse_event_type(_), do: {:ok, :checked}
  @impl true
  def event_identity(%{"id" => id}), do: {:ok, id}
  @impl true
  def handle_event(type, payload) do
    send(Application.fetch_env!(:ash_hooks, :source_test_sink), {:handled, __MODULE__})
    {:ok, %AshHooks.Event{type: type, payload: payload}}
  end
end

defmodule AshHooks.Test.DeclarationContextProvider do
  @moduledoc false
  alias AshHooks.Test.SourceProvider

  use AshHooks.Provider,
    verify: [algorithm: :hmac_sha256, signature: {:header, "x-signature"}]

  @impl true
  def parse_event_type(payload, context),
    do: SourceProvider.parse_event_type(payload, context)

  @impl true
  def event_identity(payload, context),
    do: SourceProvider.event_identity(payload, context)

  @impl true
  def handle_event(type, payload, context),
    do: SourceProvider.handle_event(type, payload, context)
end

defmodule AshHooks.Test.InboundSourceCases do
  @moduledoc false
  @compile {:no_warn_undefined, [AshHooks.Plug, Plug.Conn, Plug.Test]}
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  alias AshHooks.Errors.Unknown.KeyUnavailable
  alias AshHooks.{InboundSource, Ingress, KeyRegistry, Signing}

  alias AshHooks.Test.{
    AnswerCustodian,
    CustodySigningCases,
    KeyIssuingCases,
    OtherSourceProvider,
    SourceProvider
  }

  @kind {:standard_webhooks, :v1}
  @clock ~U[2026-11-14 12:00:00.000000Z]

  def setup_all(module, layer, repo, prefix) do
    ctx = CustodySigningCases.setup_all(module, layer, repo, prefix)
    source = Module.concat(module, Source)
    ledger = Module.concat(module, SourceLedger)

    ctx =
      Map.merge(ctx, %{
        source: source,
        source_ledger: ledger,
        source_table: prefix <> "_sources",
        source_ledger_table: prefix <> "_receipts"
      })

    compile_ledger(ctx)
    compile_source(ctx, source)
    id = if ctx.storage == :postgres, do: "UUID", else: "TEXT"
    time = if ctx.storage == :postgres, do: "TIMESTAMP(6)", else: "TEXT"
    term = if ctx.storage == :postgres, do: "BYTEA", else: "BLOB"
    json = if ctx.storage == :postgres, do: "JSONB", else: "TEXT"

    ctx.repo.query!(
      "CREATE TABLE #{ctx.source_table} (id #{id} PRIMARY KEY, tenant_id bigint NOT NULL, source TEXT NOT NULL, account_id TEXT NOT NULL, provider TEXT NOT NULL, url TEXT, secret_ref TEXT, secret_kind #{term}, previous_secret_ref TEXT, previous_secret_kind #{term}, public_key #{term}, public_key_kind #{term}, paused BOOLEAN NOT NULL DEFAULT FALSE, secret_created_at #{time}, secret_first_used_at #{time}, previous_secret_created_at #{time}, previous_secret_first_used_at #{time}, previous_secret_retired_at #{time}, CHECK (url != 'https://hooks.example.test/refuse-use' OR secret_first_used_at IS NULL))",
      [],
      log: false
    )

    ctx.repo.query!(
      "CREATE UNIQUE INDEX #{ctx.source_table}_unique_source_index ON #{ctx.source_table} (tenant_id, source, account_id)",
      [],
      log: false
    )

    ctx.repo.query!(
      "CREATE TABLE #{ctx.source_ledger_table} (id #{id} PRIMARY KEY, tenant_id bigint NOT NULL, account_id TEXT NOT NULL, provider TEXT NOT NULL, provider_alias TEXT, external_event_id TEXT NOT NULL, external_event_type TEXT, payload #{json} NOT NULL, payload_digest TEXT NOT NULL, status TEXT NOT NULL, fencing_token bigint NOT NULL DEFAULT 0, lease_expires_at #{time}, error_class TEXT, attempts bigint NOT NULL DEFAULT 0, CHECK (external_event_id != 'refuse-claim' OR attempts = 0))",
      [],
      log: false
    )

    ctx.repo.query!(
      "CREATE UNIQUE INDEX #{ctx.source_ledger_table}_unique_ingest_index ON #{ctx.source_ledger_table} (tenant_id, provider, external_event_id, account_id)",
      [],
      log: false
    )

    on_exit(fn ->
      ctx.repo.query!("DROP TABLE #{ctx.source_ledger_table}", [], log: false)
      ctx.repo.query!("DROP TABLE #{ctx.source_table}", [], log: false)

      for module <- [source, ledger] do
        :code.purge(module)
        :code.delete(module)
      end
    end)

    ctx
  end

  def clean(ctx) do
    KeyIssuingCases.clean(ctx)
    ctx.repo.query!("DELETE FROM #{ctx.source_ledger_table}", [], log: false)
    ctx.repo.query!("DELETE FROM #{ctx.source_table}", [], log: false)
    Application.put_env(:ash_hooks, :source_test_sink, self())
    on_exit(fn -> Application.delete_env(:ash_hooks, :source_test_sink) end)
    :ok
  end

  def cases do
    [
      :creation,
      :direct_ref_refused,
      :import_kinds,
      :generation_refusals,
      :roll_gate,
      :concurrent_rolls,
      :reissue,
      :concurrent_reissue_roll,
      :retirement,
      :resolution,
      :verification,
      :first_use_failure,
      :previous_key,
      :overlap_failure,
      :overlap_stale_timestamp,
      :declaration_context,
      :two_tenants,
      :unknown_source,
      :paused_source,
      :durable_provider,
      :independent_recovery,
      :nil_alias_exclusion,
      :adoption,
      :adoption_failure,
      :adoption_live_claim,
      :adoption_crash,
      :adoption_transaction,
      :concurrent_adoption,
      :adoption_validation,
      :callback_context,
      :composite_context,
      :public_key,
      :outer_transaction,
      :required_tenant,
      :missing_previous_deadline,
      :unknown_alias,
      :undated_previous
    ]
  end

  def issuing_case(ctx, name) do
    source_ctx =
      ctx
      |> Map.put(:source_owner?, true)
      |> Map.put(:endpoint, ctx.source)
      |> Map.put(:endpoint_table, ctx.source_table)

    apply(KeyIssuingCases, name, [source_ctx])
  end

  def creation(ctx) do
    for tenant <- [17, 18] do
      assert {:ok, row, "whsec_" <> _ = disclosure} = create(ctx, tenant: tenant)
      assert row.secret_kind == @kind
      assert row.secret_created_at == @clock
      assert row.secret_first_used_at == nil
      assert [registry] = Ash.read!(ctx.registry, tenant: tenant, authorize?: false)
      assert registry.owner_resource == ctx.source
      assert registry.owner_key == AshHooks.PrimaryKey.encode(row)
      assert registry.custody_tenant == Integer.to_string(tenant)
      refute inspect(row) =~ disclosure
      assert {:ok, :created, %{status: :processed}} = ingest(ctx, disclosure, tenant: tenant)
    end
  end

  def direct_ref_refused(ctx) do
    assert {:error, _} =
             Ash.create(ctx.source, attrs() |> Map.put(:secret_ref, "direct"),
               tenant: 17,
               authorize?: false
             )

    assert {:error, _} = create(ctx, attrs: attrs() |> Map.put(:secret_ref, "direct"))
    assert Enum.all?(registry_rows(ctx), &(&1.state == :retired))
  end

  def import_kinds(ctx) do
    for kind <-
          [@kind, {:standard_webhooks, :v1a}, {:legacy_hmac, :sha256}] ++
            Enum.map([:sha1, :sha256, :sha384, :sha512], &{:sender_hmac, &1}),
        tenant <- [17, 18] do
      material = :crypto.strong_rand_bytes(32)

      assert {:ok, row} =
               create(ctx,
                 material: material,
                 kind: kind,
                 tenant: tenant,
                 attrs: Map.put(attrs(), :account_id, inspect(kind))
               )

      assert row.secret_kind == kind

      assert {:ok, _} =
               InboundSource.roll_secret(row, tenant: tenant, material: material, kind: kind)
    end
  end

  def generation_refusals(ctx) do
    for kind <- [
          {:sender_hmac, :sha256},
          {:standard_webhooks, :v1a},
          {:legacy_hmac, :sha256},
          :unknown
        ] do
      assert {:error, :kind_not_allowed} = create(ctx, generate: kind)
    end

    assert registry_rows(ctx) == []

    assert {:error, :key_input_required} =
             InboundSource.create_source(ctx.source, attrs(), tenant: 17)

    for opts <- [
          [material: nil, kind: @kind],
          [material: 123, kind: @kind],
          [material: "", kind: @kind],
          [material: "sender", kind: :unknown],
          [material: "sender", kind: @kind, generate: @kind],
          [new_secret_ref: "direct"],
          [public_key: nil, kind: :ed25519],
          [public_key: <<0::256>>, generate: @kind],
          [public_key: <<0::256>>, material: :crypto.strong_rand_bytes(32), kind: @kind],
          [
            public_key: <<0::256>>,
            previous: :crypto.strong_rand_bytes(32),
            previous_retires_at: DateTime.add(DateTime.utc_now(), 60)
          ]
        ] do
      assert {:error, _} = InboundSource.create_source(ctx.source, attrs(), [tenant: 17] ++ opts)
    end

    assert registry_rows(ctx) == []
    assert {:ok, row} = create(ctx, material: "sender", kind: {:sender_hmac, :sha256})
    before = registry_rows(ctx)
    assert {:error, :kind_not_allowed} = InboundSource.reissue_secret(row, tenant: 17)

    for kind <- [
          {:sender_hmac, :sha256},
          {:standard_webhooks, :v1a},
          {:legacy_hmac, :sha256},
          :unknown
        ] do
      assert {:error, :kind_not_allowed} =
               InboundSource.roll_secret(row, tenant: 17, generate: kind)
    end

    assert registry_rows(ctx) == before
  end

  def roll_gate(ctx) do
    {:ok, row, _} = create(ctx)

    for overlap <- [-1, 1.5, "1"] do
      assert {:error, :invalid_overlap} =
               InboundSource.roll_secret(row,
                 tenant: 17,
                 generate: @kind,
                 overlap_seconds: overlap
               )
    end

    {:ok, rolled, _} =
      InboundSource.roll_secret(row,
        tenant: 17,
        generate: @kind,
        now: @clock,
        overlap_seconds: 10
      )

    assert {:error, :overlap_active} =
             InboundSource.roll_secret(rolled, tenant: 17, generate: @kind, now: @clock)

    assert {:ok, _, _} =
             InboundSource.roll_secret(rolled,
               tenant: 17,
               generate: @kind,
               now: DateTime.add(@clock, 10)
             )

    assert Enum.find(registry_rows(ctx), &(&1.ref == row.secret_ref)).state == :retired

    resource = Module.concat(ctx.source, BoundedOverlap)
    compile_source(ctx, resource, max_overlap_seconds: 60, default_overlap_seconds: 0)

    {:ok, bounded, _} =
      create(%{ctx | source: resource}, attrs: %{attrs() | account_id: "bounded"})

    before = registry_rows(ctx)

    assert {:error, {:overlap_exceeds_max, 60}} =
             InboundSource.roll_secret(bounded, tenant: 17, generate: @kind, overlap_seconds: 61)

    assert registry_rows(ctx) == before

    assert {:ok, immediate, _} =
             InboundSource.roll_secret(bounded, tenant: 17, generate: @kind, now: @clock)

    assert immediate.previous_secret_retired_at == @clock

    assert {:error, {:overlap_exceeds_max, 60}} =
             InboundSource.schedule_previous_retirement(immediate, DateTime.add(@clock, 61),
               tenant: 17,
               now: @clock
             )

    assert {:ok, _, _} =
             InboundSource.roll_secret(immediate, tenant: 17, generate: @kind, now: @clock)
  end

  def concurrent_rolls(ctx) do
    {:ok, row, _} = create(ctx)

    race([
      fn -> InboundSource.roll_secret(row, tenant: 17, generate: @kind) end,
      fn -> InboundSource.roll_secret(row, tenant: 17, generate: @kind) end
    ])
  end

  def reissue(ctx) do
    {:ok, row, previous_disclosure} = create(ctx)

    {:ok, rolled, replaced_disclosure} =
      InboundSource.roll_secret(row, tenant: 17, generate: @kind)

    assert {:ok, replaced, disclosure} = InboundSource.reissue_secret(rolled, tenant: 17)
    assert replaced.previous_secret_ref == rolled.previous_secret_ref
    assert replaced.previous_secret_retired_at == rolled.previous_secret_retired_at
    assert {:ok, :created, %{status: :processed}} = ingest(ctx, disclosure)

    assert {:ok, :created, %{status: :processed}} =
             ingest(ctx, previous_disclosure, id: "previous-after-reissue")

    assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
             ingest(ctx, replaced_disclosure, id: "replaced-after-reissue")

    assert Enum.find(registry_rows(ctx), &(&1.ref == rolled.secret_ref)).state == :retired

    assert {:ok, _} =
             KeyRegistry.sweep(ctx.registry,
               tenant: 17,
               now: DateTime.add(DateTime.utc_now(), 901)
             )

    assert Enum.find(registry_rows(ctx), &(&1.ref == rolled.secret_ref)).state == :destroyed
  end

  def concurrent_reissue_roll(ctx) do
    {:ok, row, _} = create(ctx)

    race([
      fn -> InboundSource.reissue_secret(row, tenant: 17) end,
      fn -> InboundSource.roll_secret(row, tenant: 17, generate: @kind) end
    ])
  end

  def retirement(ctx) do
    {:ok, row, _} = create(ctx)
    assert {:ok, _} = InboundSource.expire_previous_secret(row, tenant: 17)

    assert {:error, :no_previous_secret} =
             InboundSource.schedule_previous_retirement(row, DateTime.add(@clock, 10),
               tenant: 17,
               now: @clock
             )

    {:ok, rolled, _} = InboundSource.roll_secret(row, tenant: 17, generate: @kind, now: @clock)

    assert {:error, :invalid_retirement_time} =
             InboundSource.schedule_previous_retirement(rolled, :invalid, tenant: 17)

    assert {:error, :retirement_in_past} =
             InboundSource.schedule_previous_retirement(rolled, DateTime.add(@clock, -1),
               tenant: 17,
               now: @clock
             )

    assert {:ok, dated} =
             InboundSource.schedule_previous_retirement(rolled, DateTime.add(@clock, 10),
               tenant: 17,
               now: @clock
             )

    assert {:ok, 1} =
             InboundSource.expire_previous_secrets(ctx.source,
               tenant: 17,
               now: DateTime.add(@clock, 10)
             )

    assert {:ok, _, _} =
             InboundSource.roll_secret(reload(dated),
               tenant: 17,
               generate: @kind,
               overlap_seconds: 0
             )
  end

  def resolution(ctx) do
    {:ok, row, _} = create(ctx)
    observe_queries(ctx)

    assert {:ok, resolved} =
             Ingress.resolve_source(ctx.source_ledger, :checked,
               tenant: 17,
               scope: %{"account_id" => "account"}
             )

    assert resolved.name == :checked
    assert resolved.provider_alias == :first
    assert resolved.provider == SourceProvider
    assert resolved.scope == %{account_id: "account"}
    assert [%AshHooks.Custody.Key{ref: ref, tenant: "17"}] = resolved.keys
    assert ref == row.secret_ref
    assert_received {:source_query, _}

    for scope <- [
          %{},
          %{account_id: nil},
          %{account_id: %{}},
          %{account_id: ""},
          %{account_id: String.duplicate("a", 65)},
          %{account_id: "account", other: 1}
        ] do
      assert {:error, %AshHooks.Errors.Invalid.MalformedPayload{}} =
               Ingress.resolve_source(ctx.source_ledger, :checked, tenant: 17, scope: scope)
    end

    refute_received {:source_query, _}
  end

  def verification(ctx) do
    {:ok, row, disclosure} = create(ctx)
    assert {:ok, :created, %{status: :processed}} = ingest(ctx, disclosure)
    assert reload(row).secret_first_used_at
    refute reload(row).previous_secret_first_used_at

    assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
             ingest(ctx, Signing.generate_secret())

    if Code.ensure_loaded?(Plug.Test) do
      assert plug(ctx, "{}", headers: [{"x-signature", String.duplicate("0", 64)}]).status == 400
      assert_received {:host_response, {:error, %AshHooks.Errors.Invalid.InvalidSignature{}}}
    end
  end

  def previous_key(ctx) do
    previous = :crypto.strong_rand_bytes(32)

    {:ok, row, current} =
      create(ctx, previous: previous, previous_retires_at: DateTime.add(DateTime.utc_now(), 60))

    assert {:ok, _, %{status: :processed}} =
             ingest(ctx, "whsec_" <> Base.encode64(previous), id: "previous")

    assert reload(row).previous_secret_first_used_at
    refute reload(row).secret_first_used_at
    assert {:ok, _, %{status: :processed}} = ingest(ctx, current, id: "current")

    ended =
      update!(reload(row), previous_secret_retired_at: DateTime.add(DateTime.utc_now(), -1))

    assert ended.previous_secret_ref == row.previous_secret_ref

    assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
             ingest(ctx, "whsec_" <> Base.encode64(previous), id: "ended-before-sweep")

    assert {:ok, _} = InboundSource.expire_previous_secret(ended, tenant: 17)

    assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
             ingest(ctx, "whsec_" <> Base.encode64(previous), id: "expired")
  end

  def overlap_failure(ctx) do
    previous = :crypto.strong_rand_bytes(32)

    {:ok, row, _} =
      create(ctx,
        previous: previous,
        previous_retires_at: DateTime.add(DateTime.utc_now(), 60)
      )

    # Both callbacks still verify against the real store. Only the selected
    # previous reference reports the one-answer outage.
    AnswerCustodian.configure(
      ctx.custodian,
      {:for_ref, row.previous_secret_ref, {:error, :unavailable}},
      self()
    )

    Application.put_env(
      :ash_hooks,
      :issuing_custodian,
      {AshHooks.Test.AnswerCustodian, self(), ctx.repo}
    )

    assert {:error, %AshHooks.Errors.Unknown.KeyUnavailable{}} =
             ingest(ctx, "whsec_" <> Base.encode64(previous))

    assert_received {:custody_verify, current, "17", @kind}
    assert current == row.secret_ref
    assert_received {:custody_verify, previous_ref, "17", @kind}
    assert previous_ref == row.previous_secret_ref

    if Code.ensure_loaded?(Plug.Test) do
      assert AshHooks.Plug.default_response(
               {:error, KeyUnavailable.exception([])},
               AshHooks.Plug.init(resource: ctx.source_ledger, source: :checked)
             ) == {503, [{"retry-after", "60"}], ""}
    end
  end

  def overlap_stale_timestamp(ctx) do
    previous = :crypto.strong_rand_bytes(32)

    {:ok, _, current} =
      create(ctx, previous: previous, previous_retires_at: DateTime.add(DateTime.utc_now(), 60))

    for secret <- [current, "whsec_" <> Base.encode64(previous)] do
      assert {:error, %AshHooks.Errors.Invalid.StaleTimestamp{} = error} =
               ingest(ctx, secret, headers: %{"x-timestamp" => "1"})

      if Code.ensure_loaded?(Plug.Test) do
        assert {400, [], ""} = AshHooks.Plug.default_response({:error, error}, [])
      end
    end

    for secret <- [current, "whsec_" <> Base.encode64(previous)] do
      assert {:error, %AshHooks.Errors.Invalid.MalformedPayload{} = error} =
               ingest(ctx, secret, body: "{", headers: %{"x-json-check" => "required"})

      if Code.ensure_loaded?(Plug.Test) do
        assert {400, [], ""} = AshHooks.Plug.default_response({:error, error}, [])
      end
    end

    assert receipts(ctx) == []
  end

  def declaration_context(ctx) do
    observe_queries(ctx)

    for {name, provider} <- [
          configured: AshHooks.Test.DeclarationContextProvider,
          legacy: OtherSourceProvider
        ] do
      assert {:ok, resolved} =
               Ingress.resolve_source(ctx.source_ledger, name,
                 tenant: 17,
                 scope: %{account_id: "account"}
               )

      assert resolved.provider == provider
      assert resolved.record == nil
      assert resolved.provider_alias == nil
      body = Jason.encode!(%{"id" => Atom.to_string(name)})

      signature =
        Base.encode16(:crypto.mac(:hmac, :sha256, elem(declaration_secret(), 1), body),
          case: :lower
        )

      assert {:ok, _, %{status: :processed}} =
               Ingress.ingest(ctx.source_ledger, name, body, %{
                 tenant: 17,
                 scope: %{account_id: "account"},
                 headers: %{"x-signature" => signature}
               })
    end

    assert_received {:handled, SourceProvider, _, context}
    assert context.provider_alias == nil
    assert context.source == :configured
    assert context.scope == %{account_id: "account"}
    assert_received {:handled, OtherSourceProvider}
    receipt!(ctx, "declaration-recovery", :claimed, nil, provider: :configured)
    assert {:ok, 1} = Ingress.reap(ctx.source_ledger, tenant: 17)
    assert_received {:handled, SourceProvider, _, recovered}
    assert recovered.source == :configured
    assert recovered.provider_alias == nil
    assert recovered.external_event_id == "declaration-recovery"
    refute_received {:source_query, _}
  end

  def declaration_secret, do: {:ok, "declaration-verification-key"}

  def observe_queries(ctx, table \\ :source_table) do
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        ctx.repo.config()[:telemetry_prefix] ++ [:query],
        &__MODULE__.observe_query/4,
        {self(), Map.fetch!(ctx, table)}
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  def observe_query(_, _, %{query: query}, {sink, table}) do
    if String.contains?(query, table), do: send(sink, {:source_query, query})
  end

  def two_tenants(ctx) do
    {:ok, first, disclosure} = create(ctx, tenant: "017")
    {:ok, second, _} = create(ctx, tenant: 18)

    assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
             ingest(ctx, disclosure, tenant: 18)

    assert {:error, :rolled_underneath} =
             InboundSource.roll_secret(first, tenant: 18, generate: @kind)

    assert {:error, :unknown_ref} =
             ctx.custodian.verify(first.secret_ref, "18", @kind, "input", <<0::256>>)

    assert {:error, :unknown_ref} =
             ctx.custodian.verify(second.secret_ref, "17", @kind, "input", <<0::256>>)

    assert {:ok, _, _} = ingest(ctx, disclosure, tenant: 17)

    for {owner, tenant, other} <- [{first, 17, 18}, {second, 18, 17}] do
      assert {:ok, rolled, generated} =
               InboundSource.roll_secret(owner, tenant: tenant, generate: @kind)

      assert {:ok, _, %{status: :processed}} =
               ingest(ctx, generated, tenant: tenant, id: "rolled")

      assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
               ingest(ctx, generated, tenant: other, id: "foreign-roll")

      assert {:error, :rolled_underneath} = InboundSource.reissue_secret(rolled, tenant: other)
      assert {:ok, _, reissued} = InboundSource.reissue_secret(rolled, tenant: tenant)

      assert {:ok, _, %{status: :processed}} =
               ingest(ctx, reissued, tenant: tenant, id: "reissued")

      assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
               ingest(ctx, reissued, tenant: other, id: "foreign-reissue")
    end
  end

  def unknown_source(ctx) do
    assert {:error, %AshHooks.Errors.Invalid.UnknownSource{}} =
             Ingress.resolve_source(ctx.source_ledger, :checked,
               tenant: 17,
               scope: %{account_id: "missing"}
             )

    if Code.ensure_loaded?(Plug.Test) do
      conn = plug(ctx, "{}")
      assert conn.status == 404
      assert plug(ctx, "", method: :get, path: "/webhooks?challenge=ready").status == 404
    end
  end

  def paused_source(ctx) do
    {:ok, row, disclosure} = create(ctx)
    assert {:ok, paused} = InboundSource.pause(row, tenant: 17)
    assert paused.paused
    assert {:error, :source_paused} = ingest(ctx, disclosure)

    if Code.ensure_loaded?(Plug.Test) do
      assert plug(ctx, "{}").status == 503
      assert_received :paused_response
      assert_received {:host_response, {:error, :source_paused}}
      challenge = plug(ctx, "", method: :get, path: "/webhooks?challenge=ready")
      assert challenge.status == 200
      assert challenge.resp_body == "ready"
      assert plug(ctx, "", method: :get).status == 405
    end

    assert {:ok, unpaused} = InboundSource.unpause(paused, tenant: 17)
    refute unpaused.paused
    assert {:ok, _, _} = ingest(ctx, disclosure)
  end

  def durable_provider(ctx) do
    {:ok, row, disclosure} = create(ctx)
    receipt = receipt!(ctx, "same", :failed_retryable, :first)
    update!(row, provider: :second)
    assert {:ok, :duplicate, %{status: :processed}} = ingest(ctx, disclosure, id: "same")
    assert_received {:handled, SourceProvider, _, context}
    assert context.delivery_id == receipt.id
    refute_received {:handled, OtherSourceProvider}
  end

  def independent_recovery(ctx) do
    for mutation <- [:delete, :pause, :rekey] do
      {:ok, row, _} = create(ctx, attrs: Map.put(attrs(), :account_id, Atom.to_string(mutation)))

      receipt!(ctx, Atom.to_string(mutation), :claimed, :first,
        account_id: Atom.to_string(mutation)
      )

      case mutation do
        :delete -> Ash.destroy!(row, tenant: 17, authorize?: false)
        :pause -> InboundSource.pause(row, tenant: 17)
        :rekey -> InboundSource.roll_secret(row, tenant: 17, generate: @kind)
      end
    end

    observe_queries(ctx)
    assert {:ok, 3} = Ingress.reap(ctx.source_ledger, tenant: 17)
    assert Enum.all?(receipts(ctx), &(&1.status == :processed))
    refute_received {:source_query, _}
  end

  def nil_alias_exclusion(ctx) do
    {:ok, _, disclosure} = create(ctx)

    for {status, id} <- [received: "received", failed_retryable: "retry", claimed: "claimed"] do
      row = receipt!(ctx, id, status, nil)
      assert {:error, :lease_held} = Ingress.claim_delivery(ctx.source_ledger, row.id, tenant: 17)
      assert {:ok, :duplicate, duplicate} = ingest(ctx, disclosure, id: id)
      assert duplicate.attempts == 0
    end

    assert {:ok, 0} = Ingress.reap(ctx.source_ledger, tenant: 17)
    refute_received {:handled, _, _, _}
  end

  def adoption(ctx) do
    for id <- ["one", "two"], do: receipt!(ctx, id, :received, nil)
    receipt!(ctx, "terminal", :processed, nil)
    receipt!(ctx, "other-tenant", :received, nil, tenant: 18)
    assert {:ok, %{driven: 1, remaining: 1}} = adopt(ctx, limit: 1)
    assert {:ok, %{driven: 1, remaining: 0}} = adopt(ctx, limit: 1)
    assert {:ok, %{driven: 0, remaining: 0}} = adopt(ctx)
    assert_received {:handled, SourceProvider, _, _}
    assert Enum.find(receipts(ctx), &(&1.external_event_id == "terminal")).provider_alias == nil
    assert hd(receipts(ctx, 18)).provider_alias == nil
  end

  def adoption_failure(ctx) do
    receipt!(ctx, "retry", :received, nil, payload: %{"id" => "retry", "retry" => true})
    assert {:ok, %{driven: 1, remaining: 0}} = adopt(ctx)
    assert hd(receipts(ctx)).status == :failed_retryable
  end

  def adoption_live_claim(ctx) do
    row = receipt!(ctx, "live", :claimed, nil, lease: DateTime.add(DateTime.utc_now(), 60))
    assert {:ok, %{driven: 0, remaining: 1}} = adopt(ctx)
    update!(row, lease_expires_at: DateTime.add(DateTime.utc_now(), -60))
    assert {:ok, %{driven: 1, remaining: 0}} = adopt(ctx)
  end

  def adoption_crash(ctx) do
    row = receipt!(ctx, "crash", :received, nil, payload: %{"id" => "crash", "block" => true})
    {pid, monitor} = spawn_monitor(fn -> adopt(ctx) end)
    assert_receive {:handled, SourceProvider, ^pid, _}, 15_000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    row = Ash.get!(ctx.source_ledger, row.id, tenant: 17, authorize?: false)
    assert row.provider_alias == :first
    assert row.status == :claimed

    update!(row,
      lease_expires_at: DateTime.add(DateTime.utc_now(), -60),
      payload: %{"id" => "crash"}
    )

    assert {:ok, 1} = Ingress.reap(ctx.source_ledger, tenant: 17)
    assert hd(receipts(ctx)).status == :processed
  end

  def adoption_transaction(ctx) do
    receipt!(ctx, "transaction", :received, nil)
    observe_queries(ctx, :source_ledger_table)
    assert length(receipts(ctx)) == 1
    assert_received {:source_query, _}
    assert {:ok, {:error, :inside_transaction}} = ctx.repo.transaction(fn -> adopt(ctx) end)
    refute_received {:source_query, _}
    assert hd(receipts(ctx)).provider_alias == nil
    refute_received {:handled, _, _, _}
  end

  def concurrent_adoption(ctx) do
    for id <- 1..3, do: receipt!(ctx, "race-#{id}", :received, nil)

    results =
      1..2
      |> Enum.map(fn _ -> Task.async(fn -> adopt(ctx) end) end)
      |> Enum.map(&Task.await(&1, 15_000))

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert Enum.sum(Enum.map(results, fn {:ok, result} -> result.driven end)) == 3
    assert Enum.all?(receipts(ctx), &(&1.attempts == 1))
  end

  def adoption_validation(ctx) do
    for opts <- [[expected_provider: OtherSourceProvider], [limit: 0], [limit: -1]] do
      assert {:error, _} = adopt(ctx, opts)
    end

    assert {:error, _} =
             InboundSource.adopt_provider_alias(ctx.source, :missing, :first, tenant: 17)

    assert {:error, _} =
             InboundSource.adopt_provider_alias(ctx.source, :checked, :unknown, tenant: 17)

    assert {:error, :tenant_required} =
             InboundSource.adopt_provider_alias(ctx.source, :checked, :first)

    row = receipt!(ctx, "refuse-claim", :received, nil)
    assert {:error, _} = adopt(ctx)
    assert reload(row).provider_alias == nil
    assert reload(row).attempts == 0
    refute_received {:handled, _, _, _}
  end

  def first_use_failure(ctx) do
    {:ok, source, disclosure} =
      create(ctx, attrs: Map.put(attrs(), :url, "https://hooks.example.test/refuse-use"))

    assert {:error, _} = ingest(ctx, disclosure)
    assert reload(source).secret_first_used_at == nil
    assert receipts(ctx) == []
    refute_received {:handled, _, _, _}
  end

  def callback_context(ctx) do
    {:ok, _, disclosure} = create(ctx)
    assert {:ok, _, row} = ingest(ctx, disclosure, tenant: "017")
    assert_received {:parsed, parsed}
    assert_received {:identified, identified}

    for context <- [parsed, identified] do
      assert context.__struct__ == AshHooks.Provider.DeliveryContext
      assert context.tenant == "017"
      assert context.source == :checked
      assert context.scope == %{account_id: "account"}
      assert context.provider_alias == :first
      assert context.delivery_id == nil
      assert context.external_event_id == nil
    end

    assert_received {:handled, SourceProvider, _, handled}
    assert handled.tenant == row.tenant_id
    assert handled.delivery_id == row.id
    assert handled.external_event_id == row.external_event_id
    assert handled.scope == parsed.scope
    receipt!(ctx, "recovered", :claimed, :first)
    assert {:ok, 1} = Ingress.reap(ctx.source_ledger, tenant: 17)
    assert_receive {:handled, SourceProvider, _, recovered}
    assert recovered.tenant == row.tenant_id
    assert recovered.external_event_id == "recovered"
    assert recovered.scope == parsed.scope
  end

  def composite_context(ctx) do
    ctx = %{
      ctx
      | source: Module.concat(ctx.source, CompositeLedger),
        source_ledger: Module.concat(ctx.source_ledger, CompositeLedger)
    }

    compile_ledger(ctx, true)
    compile_source(ctx, ctx.source)
    on_exit(fn -> purge_modules([ctx.source, ctx.source_ledger]) end)

    {:ok, _, disclosure} = create(ctx)
    assert {:ok, _, row} = ingest(ctx, disclosure)
    assert_received {:handled, SourceProvider, _, context}
    assert context.delivery_id == %{id: row.id, account_id: row.account_id}

    receipt!(ctx, "composite-recovery", :claimed, :first)
    assert {:ok, 1} = Ingress.reap(ctx.source_ledger, tenant: 17)
    assert_received {:handled, SourceProvider, _, recovered}
    assert recovered.external_event_id == "composite-recovery"
    assert recovered.delivery_id.account_id == row.account_id
  end

  def public_key(ctx) do
    owners =
      for tenant <- [17, 18] do
        {public, private} = :crypto.generate_key(:eddsa, :ed25519)
        assert {:ok, row} = create(ctx, tenant: tenant, public_key: public, kind: :ed25519)
        {tenant, row, private}
      end

    for {tenant, row, private} <- owners do
      other = if tenant == 17, do: 18, else: 17
      body = Jason.encode!(%{"id" => "foreign-public"})
      signature = Base.encode64(:crypto.sign(:eddsa, :none, body, [private, :ed25519]))

      assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
               Ingress.ingest(ctx.source_ledger, :checked, body, %{
                 tenant: other,
                 scope: %{account_id: "account"},
                 headers: %{"x-signature" => signature}
               })

      assert {:error, :rolled_underneath} =
               InboundSource.register_public_key(row, row.public_key,
                 tenant: other,
                 kind: :ed25519
               )
    end

    for {tenant, row, private} <- owners do
      assert row.secret_ref == nil
      assert row.public_key_kind == :ed25519
      body = Jason.encode!(%{"id" => "public"})
      signature = Base.encode64(:crypto.sign(:eddsa, :none, body, [private, :ed25519]))

      assert {:ok, _, %{status: :processed}} =
               Ingress.ingest(ctx.source_ledger, :checked, body, %{
                 tenant: tenant,
                 scope: %{account_id: "account"},
                 headers: %{"x-signature" => signature}
               })

      {next_public, _} = :crypto.generate_key(:eddsa, :ed25519)

      assert {:ok, replaced} =
               InboundSource.register_public_key(row, next_public, tenant: tenant, kind: :ed25519)

      assert replaced.public_key == next_public

      assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
               Ingress.ingest(ctx.source_ledger, :checked, body, %{
                 tenant: tenant,
                 scope: %{account_id: "account"},
                 headers: %{"x-signature" => signature}
               })

      update!(replaced, public_key: nil)

      assert {:error, %AshHooks.Errors.Invalid.NoWebhookSecret{}} =
               Ingress.ingest(ctx.source_ledger, :checked, body, %{
                 tenant: tenant,
                 scope: %{account_id: "account"},
                 headers: %{"x-signature" => signature}
               })
    end

    assert registry_rows(ctx) == []
  end

  def required_tenant(ctx) do
    {:ok, row, _} = create(ctx)

    for operation <- [
          fn -> InboundSource.create_source(ctx.source, attrs()) end,
          fn -> InboundSource.reissue_secret(row) end,
          fn -> InboundSource.schedule_previous_retirement(row, DateTime.utc_now()) end,
          fn -> InboundSource.expire_previous_secret(row) end,
          fn -> InboundSource.expire_previous_secrets(ctx.source) end,
          fn -> InboundSource.register_public_key(row, <<0::256>>) end,
          fn -> InboundSource.pause(row) end,
          fn -> InboundSource.unpause(row) end,
          fn -> InboundSource.adopt_provider_alias(ctx.source, :checked, :first) end
        ] do
      assert {:error, :tenant_required} = operation.()
    end

    assert {:error, :tenant_required} = InboundSource.roll_secret(row)

    assert {:error, %AshHooks.Errors.Invalid.MalformedPayload{}} =
             Ingress.resolve_source(ctx.source_ledger, :checked)
  end

  def outer_transaction(ctx) do
    {:ok, row, _} = create(ctx)
    before = registry_rows(ctx)

    assert {:ok, :ok} =
             ctx.repo.transaction(fn ->
               for operation <- [
                     fn -> create(ctx) end,
                     fn -> InboundSource.roll_secret(row, tenant: 17, generate: @kind) end,
                     fn -> InboundSource.reissue_secret(row, tenant: 17) end,
                     fn -> create(ctx, public_key: <<0::256>>, kind: :ed25519) end
                   ] do
                 assert {:error, :inside_transaction} = operation.()
               end

               :ok
             end)

    assert registry_rows(ctx) == before
  end

  def missing_previous_deadline(ctx) do
    assert {:error, :previous_secret_undated} =
             create(ctx, previous: :crypto.strong_rand_bytes(32))

    assert {:error, :invalid_retirement_time} =
             create(ctx, previous: :crypto.strong_rand_bytes(32), previous_retires_at: :invalid)

    assert registry_rows(ctx) == []
    Process.put(:issuing_store_answer, {:next_store, {:error, :invalid_material}})

    assert {:error, :invalid_material} =
             create(ctx,
               previous: :crypto.strong_rand_bytes(32),
               previous_retires_at: DateTime.add(DateTime.utc_now(), 60)
             )

    assert length(registry_rows(ctx)) == 2
    assert Enum.all?(registry_rows(ctx), &(&1.state == :retired))
  end

  def unknown_alias(ctx) do
    {:ok, row, _} = create(ctx)
    # Database rows can outlive a removed alias, so runtime resolution must fail closed.
    marker = if ctx.storage == :postgres, do: "$1", else: "?1"

    ctx.repo.query!(
      "UPDATE #{ctx.source_table} SET provider = 'removed' WHERE tenant_id = #{marker}",
      [17],
      log: false
    )

    assert {:error, %AshHooks.Errors.Unknown.UnknownError{}} =
             Ingress.resolve_source(ctx.source_ledger, :checked,
               tenant: 17,
               scope: %{account_id: row.account_id}
             )
  end

  def undated_previous(ctx) do
    previous = :crypto.strong_rand_bytes(32)

    {:ok, row, _} =
      create(ctx, previous: previous, previous_retires_at: DateTime.add(DateTime.utc_now(), 60))

    row = update!(row, previous_secret_retired_at: nil)

    assert {:error, :previous_secret_undated} =
             InboundSource.roll_secret(row, tenant: 17, generate: @kind)

    assert {:ok, resolved} =
             Ingress.resolve_source(ctx.source_ledger, :checked,
               tenant: 17,
               scope: %{account_id: "account"}
             )

    assert length(resolved.keys) == 1

    assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
             ingest(ctx, "whsec_" <> Base.encode64(previous))

    assert {:ok, 0} = InboundSource.expire_previous_secrets(ctx.source, tenant: 17)
    assert {:ok, expired} = InboundSource.expire_previous_secret(row, tenant: 17)
    assert {:ok, _, _} = InboundSource.roll_secret(expired, tenant: 17, generate: @kind)
  end

  def create(ctx, opts \\ []) do
    {attributes, opts} = Keyword.pop(opts, :attrs, attrs())
    opts = Keyword.merge([tenant: 17, now: @clock], opts)

    opts =
      if opts[:material] || opts[:public_key],
        do: opts,
        else: Keyword.put_new(opts, :generate, @kind)

    InboundSource.create_source(ctx.source, attributes, opts)
  end

  defp attrs, do: %{source: :checked, account_id: "account", provider: :first}

  def ingest(ctx, disclosure, opts \\ []) do
    body = Keyword.get(opts, :body, Jason.encode!(%{"id" => Keyword.get(opts, :id, "event")}))
    "whsec_" <> encoded = disclosure
    key = Base.decode64!(encoded)
    signature = Base.encode16(:crypto.mac(:hmac, :sha256, key, body), case: :lower)

    Ingress.ingest(
      ctx.source_ledger,
      :checked,
      body,
      %{
        headers: Map.merge(%{"x-signature" => signature}, Keyword.get(opts, :headers, %{})),
        tenant: Keyword.get(opts, :tenant, 17),
        scope: %{account_id: Keyword.get(opts, :account_id, "account")}
      }
    )
  end

  defp adopt(ctx, opts \\ []),
    do:
      InboundSource.adopt_provider_alias(
        ctx.source,
        :checked,
        :first,
        Keyword.merge([tenant: 17, expected_provider: SourceProvider], opts)
      )

  defp registry_rows(ctx), do: Ash.read!(ctx.registry, tenant: 17, authorize?: false)

  defp receipts(ctx, tenant \\ 17),
    do: Ash.read!(ctx.source_ledger, tenant: tenant, authorize?: false)

  defp reload(row), do: Ash.get!(row.__struct__, row.id, tenant: row.tenant_id, authorize?: false)

  defp update!(row, attributes),
    do:
      row
      |> Ash.Changeset.for_update(:update, %{}, tenant: row.tenant_id)
      |> Ash.Changeset.force_change_attributes(Map.new(attributes))
      |> Ash.update!(authorize?: false)

  defp receipt!(ctx, id, status, alias, opts \\ []) do
    tenant = Keyword.get(opts, :tenant, 17)

    ctx.source_ledger
    |> Ash.Changeset.for_create(
      :ingest,
      %{
        provider: Keyword.get(opts, :provider, :checked),
        provider_alias: alias,
        account_id: Keyword.get(opts, :account_id, "account"),
        external_event_id: id,
        payload: Keyword.get(opts, :payload, %{"id" => id}),
        payload_digest: "digest"
      },
      tenant: tenant
    )
    |> Ash.Changeset.force_change_attributes(%{
      status: status,
      lease_expires_at: Keyword.get(opts, :lease, DateTime.add(DateTime.utc_now(), -60))
    })
    |> Ash.create!(authorize?: false)
  end

  defp race(operations) do
    results = operations |> Enum.map(&Task.async/1) |> Enum.map(&Task.await(&1, 15_000))
    assert Enum.count(results, &match?({:ok, _, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :rolled_underneath})) == 1
  end

  defp plug(ctx, body, opts \\ []) do
    options =
      AshHooks.Plug.init(
        resource: ctx.source_ledger,
        resolve: {__MODULE__, :plug_context, []},
        respond: {__MODULE__, :host_response, []}
      )

    conn =
      Plug.Test.conn(
        Keyword.get(opts, :method, :post),
        Keyword.get(opts, :path, "/webhooks"),
        body
      )

    opts
    |> Keyword.get(:headers, [])
    |> Enum.reduce(conn, fn {name, value}, conn -> Plug.Conn.put_req_header(conn, name, value) end)
    |> AshHooks.Plug.call(options)
  end

  def host_response(outcome) do
    send(Application.fetch_env!(:ash_hooks, :source_test_sink), {:host_response, outcome})
    :default
  end

  def plug_context(_conn),
    do: {:ok, %{source: :checked, tenant: 17, scope: %{account_id: "account"}}}

  def compile_source(ctx, module, opts \\ []) do
    storage = storage(ctx, ctx.source_table)

    tenant_attribute =
      if is_nil(ctx[:endpoint_attributes]),
        do: quote(do: attribute(:tenant_id, :integer, allow_nil?: false, public?: true))

    overlap_options =
      for {option, value} <- Keyword.take(opts, [:max_overlap_seconds, :default_overlap_seconds]),
          do: {option, [], [value]}

    definitions =
      Code.compile_quoted(
        quote do
          defmodule unquote(module) do
            use Ash.Resource,
              domain: unquote(ctx.domain),
              data_layer: unquote(ctx.layer),
              extensions: [AshHooks.InboundSource]

            unquote(storage)

            attributes do
              unquote(tenant_attribute)

              attribute(:url, AshHooks.Endpoint.Url, public?: true)
              unquote(ctx[:endpoint_attributes])
            end

            multitenancy do
              strategy(:attribute)
              attribute(:tenant_id)
            end

            inbound_source do
              ledger(unquote(ctx.source_ledger))
              scope([{:account_id, :string, [max_length: 64]}])
              providers(first: SourceProvider, second: OtherSourceProvider)
              custodian(unquote(Keyword.get(opts, :custodian, AshHooks.Test.IssuingCustodian)))
              key_registry(unquote(ctx.registry))

              unquote_splicing(overlap_options)
            end

            actions do
              defaults([:read, :destroy, create: :*, update: :*])
            end

            unquote(ctx[:endpoint_changes])
            unquote(ctx[:endpoint_identities])
          end
        end
      )

    if module != ctx.source do
      modules = Enum.map(definitions, &elem(&1, 0))
      on_exit(fn -> purge_modules(modules) end)
    end

    module
  end

  defp purge_modules(modules) do
    for module <- modules do
      :code.purge(module)
      :code.delete(module)
    end
  end

  defp compile_ledger(ctx, composite? \\ false) do
    storage = storage(ctx, ctx.source_ledger_table)

    attributes =
      if composite? do
        quote do
          uuid_primary_key(:id)

          attribute(:account_id, :string,
            allow_nil?: false,
            constraints: [max_length: 64],
            primary_key?: true
          )
        end
      else
        quote do
          attribute(:account_id, :string, allow_nil?: false, constraints: [max_length: 64])
        end
      end

    Code.compile_quoted(
      quote do
        defmodule unquote(ctx.source_ledger) do
          use Ash.Resource,
            domain: unquote(ctx.domain),
            data_layer: unquote(ctx.layer),
            extensions: [AshHooks, AshHooks.InboundDelivery]

          unquote(storage)

          attributes do
            attribute(:tenant_id, :integer, allow_nil?: false)
            unquote(attributes)
          end

          multitenancy do
            strategy(:attribute)
            attribute(:tenant_id)
          end

          inbound_delivery do
            scope_identity([:account_id])
            record_provider_alias(:on)
          end

          webhooks do
            inbound :checked do
              source_record(unquote(ctx.source))
            end

            inbound :configured do
              provider(AshHooks.Test.DeclarationContextProvider)
              secret({unquote(__MODULE__), :declaration_secret, []})
            end

            inbound :legacy do
              provider(AshHooks.Test.OtherSourceProvider)
              secret({unquote(__MODULE__), :declaration_secret, []})
            end
          end

          actions do
            defaults([:read, update: :*])
          end
        end
      end
    )
  end

  defp storage(ctx, table),
    do:
      {ctx.storage, [],
       [
         [
           do:
             quote(
               do:
                 (
                   repo(unquote(ctx.repo))
                   table(unquote(table))
                 )
             )
         ]
       ]}
end
