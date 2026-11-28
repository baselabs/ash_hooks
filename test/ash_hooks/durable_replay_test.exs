defmodule AshHooks.DurableReplayTest.Provider do
  @moduledoc false
  use AshHooks.Provider, verify: [algorithm: :hmac_sha256, signature: {:header, "x-signature"}]

  @impl true
  def verification_coverage, do: :body_only_mac

  @impl true
  def verify_signature(body, context, keys) do
    with :ok <- super(body, context, keys), do: {:ok, %{"authenticated" => true}}
  end

  @impl true
  def decode_payload(body) do
    notify(:decoded)
    Jason.decode(body)
  end

  @impl true
  def event_identity(_payload), do: raise("protected routes own the identity")

  @impl true
  def handle_event(type, payload) do
    notify({:handled, payload})
    AshHooks.CountingProvider.handle_event(type, payload)
  end

  @impl true
  def response(outcome) do
    notify({:provider_response, outcome})
    :default
  end

  defp notify(message) do
    send(Application.fetch_env!(:ash_hooks, __MODULE__), message)
  end
end

defmodule AshHooks.DurableReplayTest.Cases do
  @moduledoc false

  defmacro __using__(opts) do
    layer = Keyword.fetch!(opts, :layer)
    repo = Keyword.fetch!(opts, :repo)
    table = Keyword.fetch!(opts, :table)
    domain = Module.concat(__CALLER__.module, Domain)
    ledger = Module.concat(__CALLER__.module, Ledger)
    legacy_ledger = Module.concat(__CALLER__.module, LegacyLedger)
    retired_ledger = Module.concat(__CALLER__.module, RetiredLedger)

    storage =
      if layer == :sqlite, do: {"TEXT", "TEXT", "TEXT"}, else: {"UUID", "JSONB", "TIMESTAMP(6)"}

    data_layer = if layer == :sqlite, do: AshSqlite.DataLayer, else: AshPostgres.DataLayer

    storage_section =
      {layer, [],
       [
         [
           do:
             quote do
               table(unquote(table))
               repo(unquote(repo))
             end
         ]
       ]}

    legacy =
      quote do
        provider(AshHooks.CountingProvider)
        secret(&unquote(__MODULE__).legacy/1)
      end

    retired =
      quote do
        provider(AshHooks.DurableReplayTest.Provider)
        replay_protection(:retired)
      end

    protected =
      quote do
        provider(AshHooks.DurableReplayTest.Provider)
        secret(&unquote(__MODULE__).current/1)
        previous_secret(&unquote(__MODULE__).previous/1)
        replay_protection(:durable_identity)
        source_binding(:authenticated)
      end

    resources =
      for {name, route} <- [Ledger: protected, LegacyLedger: legacy, RetiredLedger: retired] do
        module = Module.concat(__CALLER__.module, name)
        protected_ledger? = name != :LegacyLedger

        read_probe =
          quote do
            prepare(
              before_action(fn query, _context ->
                unquote(__MODULE__).check_storage(query, unquote(repo), unquote(table))
              end)
            )
          end

        quote do
          defmodule unquote(module) do
            @moduledoc false
            use Ash.Resource,
              domain: unquote(domain),
              data_layer: unquote(data_layer),
              extensions: [AshHooks, AshHooks.InboundDelivery],
              authorizers: [Ash.Policy.Authorizer]

            unquote(storage_section)

            attributes do
              attribute(:tenant_slug, :string, allow_nil?: false)
              timestamps()
            end

            multitenancy do
              strategy(:attribute)
              attribute(:tenant_slug)
            end

            actions do
              read :read do
                primary?(true)
                unquote(read_probe)
              end
            end

            policies do
              policy action_type(:read) do
                authorize_if(always())
              end

              policy action(unquote(admission_actions(protected_ledger?))) do
                authorize_if(actor_present())
              end
            end

            inbound_delivery do
              retain_replay_identities(unquote(if protected_ledger?, do: :on, else: :off))
              record_verified_facts(:on)
            end

            webhooks do
              inbound :protected do
                unquote(route)
              end

              inbound :legacy do
                unquote(legacy)
              end
            end
          end
        end
      end

    quote do
      use ExUnit.Case, async: false
      @compile {:no_warn_undefined, [AshHooks.Plug, Plug.Conn, Plug.Test]}
      unquote(if layer == :postgres, do: quote(do: @moduletag(:postgres)))
      alias AshHooks.DurableReplayTest.Provider
      alias AshHooks.Ingress
      alias unquote(repo), as: Repo
      alias unquote(ledger), as: Ledger
      alias unquote(legacy_ledger), as: LegacyLedger
      alias unquote(retired_ledger), as: RetiredLedger

      @table unquote(table)
      @service_actor %{id: "trusted-replay-service"}

      unquote_splicing(resources)

      defmodule unquote(domain) do
        @moduledoc false
        use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

        resources do
          resource(unquote(ledger))
          resource(unquote(legacy_ledger))
          resource(unquote(retired_ledger))
        end
      end

      setup_all do
        {id_type, payload_type, time_type} = unquote(Macro.escape(storage))

        Repo.query!("""
        CREATE TABLE #{@table} (
          id #{id_type} PRIMARY KEY NOT NULL,
          tenant_slug TEXT NOT NULL, provider TEXT NOT NULL,
          external_event_id TEXT NOT NULL, external_event_type TEXT,
          payload #{payload_type} NOT NULL, payload_digest TEXT NOT NULL,
          verified_facts #{payload_type}, replay_identity TEXT,
          status TEXT NOT NULL, fencing_token INTEGER NOT NULL,
          lease_expires_at #{time_type}, error_class TEXT, attempts INTEGER NOT NULL,
          inserted_at #{time_type} NOT NULL, updated_at #{time_type} NOT NULL
        )
        """)

        Repo.query!("""
        CREATE UNIQUE INDEX #{@table}_unique_ingest_index
        ON #{@table} (tenant_slug, provider, external_event_id)
        """)

        on_exit(fn -> Repo.query!("DROP TABLE #{@table}") end)
        :ok
      end

      setup do
        Repo.query!("DELETE FROM #{@table}")
        Application.put_env(:ash_hooks, Provider, self())
        AshHooks.CountingProvider.put_outcome(:ok)

        on_exit(fn ->
          Application.delete_env(:ash_hooks, Provider)
          AshHooks.CountingProvider.cleanup()
        end)

        :ok
      end

      unquote(retention_cases())
      unquote(storage_cases(layer))
      unquote(admission_cases())
      unquote(entry_point_cases())
      unquote(row_security_cases(layer))
      unquote(ingress_helpers())
    end
  end

  defp retention_cases() do
    quote do
      test "atomic ledger writes work with a host primary read hook" do
        Process.put(:check_replay_storage, true)
        assert [] = Ash.read!(Ledger, tenant: "a")
        assert_received :checked_replay_storage

        body = ~s({"type":"processed","id":"host-read-hook"})
        assert {:ok, :created, %{status: :processed, fencing_token: 1}} = ingest(:protected, body)
        assert {:ok, 1} = compact()
        assert {:ok, 0} = Ingress.prune(Ledger, tenant: "a", older_than: future())
        assert [%{replay_identity: :compacted}] = Ash.read!(Ledger, tenant: "a")
      end

      test "legacy prune reopens admission while terminal compaction preserves one receipt and effect" do
        body = ~s({"type":"processed","personal":"erase"})
        assert {:ok, :created, legacy} = ingest(:legacy, body)
        assert legacy.status == :processed
        assert {:ok, 1} = Ingress.prune(Ledger, tenant: "a", older_than: future())
        assert {:ok, :created, new_legacy} = ingest(:legacy, body)
        assert new_legacy.id != legacy.id

        assert {:ok, :created, accepted} = ingest(:protected, body)
        assert accepted.replay_identity == :retained
        assert accepted.verified_facts == %{"authenticated" => true}
        assert_receive :decoded
        assert_receive {:handled, %{"personal" => "erase"}}
        assert {:ok, 0} = compact(accepted.inserted_at)
        assert {:ok, 1} = compact()
        assert {:ok, 0} = compact()
        assert {:ok, 1} = Ingress.prune(Ledger, tenant: "a", older_than: future())

        assert {:ok, :duplicate, retained} =
                 ingest(:protected, body, headers: [{"x-topic", "forged"}])

        assert retained.id == accepted.id
        assert retained.status == :processed
        assert retained.payload == %{}
        assert retained.replay_identity == :compacted
        assert retained.external_event_type == nil
        assert retained.verified_facts == nil
        refute_receive :decoded
        refute_receive {:handled, _}
        assert [^retained] = Ash.read!(Ledger, tenant: "a")
      end

      test "claimed and recoverable deliveries retain the first payload during concurrent cleanup" do
        owner = self()

        AshHooks.CountingProvider.put_outcome(fn ->
          send(owner, {:claim_held, self()})

          receive do
            :complete -> :ok
          end
        end)

        body = ~s({"type":"processed","personal":"first"})
        admission = Task.async(fn -> ingest(:protected, body) end)

        assert_receive {:claim_held, worker}, 5_000
        assert_receive {:handled, %{"personal" => "first"}}
        assert {:ok, 0} = compact()
        assert {:ok, 0} = Ingress.prune(Ledger, tenant: "a", older_than: future())
        assert {:ok, :duplicate, claimed} = ingest(:protected, body)
        assert claimed.status == :claimed
        assert claimed.payload["personal"] == "first"

        assert {:error, :protected_receipt} =
                 Ingress.redact_payload(
                   Ledger,
                   claimed.id,
                   claimed.fencing_token,
                   fn _ -> flunk("protected payload cannot be redacted during a claim") end,
                   tenant: "a"
                 )

        assert {:error, _error} =
                 Ash.update(claimed, %{},
                   action: :compact_replay_receipt,
                   actor: @service_actor,
                   tenant: "a"
                 )

        refute_receive {:handled, _}

        send(worker, :complete)
        assert {:ok, :created, terminal} = Task.await(admission, 5_000)

        concurrent =
          [
            Task.async(fn -> compact() end),
            Task.async(fn -> ingest(:protected, body) end),
            Task.async(fn -> Ingress.prune(Ledger, tenant: "a", older_than: future()) end)
          ]
          |> Task.await_many(10_000)

        assert [{:ok, 1}, {:ok, :duplicate, duplicate}, {:ok, 0}] = concurrent
        assert duplicate.id == terminal.id
        refute_receive {:handled, _}
        assert [%{replay_identity: :compacted}] = Ash.read!(Ledger, tenant: "a")
      end

      test "overlap and rotation preserve identity and isolate tenants on the first presentation" do
        body = ~s({"type":"processed","id":"same"})

        assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
                 ingest(:protected, body, tenant: "b", key_slot: :previous, signing_tenant: "a")

        assert Ash.read!(Ledger, tenant: "b") == []
        assert {:ok, :created, first} = ingest(:protected, body, key_slot: :previous)
        assert {:ok, 1} = compact()

        assert {:ok, :duplicate, %{id: id}} = ingest(:protected, body)
        assert id == first.id

        assert {:ok, :created, other} = ingest(:protected, body, tenant: "b")
        assert other.id != first.id
        assert other.external_event_id == first.external_event_id

        distinct_bytes = body <> "\n"
        assert {:ok, :created, distinct} = ingest(:protected, distinct_bytes)
        assert distinct.external_event_id != first.external_event_id
      end
    end
  end

  defp storage_cases(layer) do
    quote do
      test "database refusal cannot admit an unreserved identity or evict the first identity" do
        body = ~s({"type":"processed","id":"first"})
        assert {:ok, :created, first} = ingest(:protected, body)
        assert_receive {:handled, %{"id" => "first"}}
        assert {:ok, 1} = compact()
        cutoff = unquote(__MODULE__).limit_capacity!(unquote(layer), Repo, @table)
        on_exit(cutoff)
        over_capacity = ~s({"type":"processed","id":"over-capacity"})

        assert {:error, %AshHooks.Errors.Unknown.ReplayStoreUnavailable{} = error} =
                 ingest(:protected, over_capacity)

        assert Exception.message(error) == "webhook replay storage is unavailable"

        if Code.ensure_loaded?(Plug.Test) do
          conn = http_ingest(Ledger, over_capacity)
          assert conn.status == 503

          assert Plug.Conn.get_resp_header(conn, "webhook-error-code") == [
                   "dependency_unavailable"
                 ]

          assert Plug.Conn.get_resp_header(conn, "retry-after") == ["60"]
          refute_received {:provider_response, _}
          refute_received {:host_response, _}
        end

        refute_receive {:handled, _}
        assert {:ok, :duplicate, %{id: id}} = ingest(:protected, body)
        assert id == first.id
        assert [%{id: ^id}] = Ash.read!(Ledger, tenant: "a")
      end

      test "storage lookup failure refuses before decoding or running the handler" do
        Repo.query!("ALTER TABLE #{@table} RENAME TO #{@table}_offline")

        try do
          assert {:error, %AshHooks.Errors.Unknown.ReplayStoreUnavailable{}} =
                   ingest(:protected, ~s({"type":"processed"}))

          refute_receive :decoded
          refute_receive {:handled, _}
        after
          Repo.query!("ALTER TABLE #{@table}_offline RENAME TO #{@table}")
        end
      end

      test "a raised repository error during the admission read is retryable" do
        Repo.query!("ALTER TABLE #{@table} RENAME TO #{@table}_offline")
        Process.put(:check_replay_storage, true)

        try do
          assert {:error, %AshHooks.Errors.Unknown.ReplayStoreUnavailable{}} =
                   ingest(:protected, ~s({"id":"raised-read"}))

          assert_received :checked_replay_storage
          refute_receive :decoded
          refute_receive {:handled, _}
        after
          Process.delete(:check_replay_storage)
          Repo.query!("ALTER TABLE #{@table}_offline RENAME TO #{@table}")
        end
      end

      test "a valid MAC over malformed bytes reserves a terminal protected receipt" do
        body = "{"
        assert {:ok, :created, receipt} = ingest(:protected, body)
        assert receipt.status == :failed_permanent
        assert receipt.error_class == "malformed_payload"
        assert receipt.replay_identity == :retained

        assert_receive :decoded
        refute_receive {:handled, _}
        assert {:ok, 1} = compact()
        assert {:ok, :duplicate, duplicate} = ingest(:protected, body)
        assert duplicate.id == receipt.id
        assert duplicate.status == :failed_permanent
        refute_receive :decoded
      end
    end
  end

  defp admission_cases() do
    quote do
      test "a matching legacy receipt without a replay marker fails closed" do
        body = ~s({"id":"legacy-collision"})
        digest = Base.encode16(:crypto.hash(:sha256, body), case: :lower)

        assert {:ok, true, legacy} =
                 Ingress.ingest_delivery(LegacyLedger, %{
                   name: :protected,
                   external_event_id: "body-sha256:v1:" <> digest,
                   type_string: nil,
                   digest: digest,
                   payload: %{},
                   tenant: "a",
                   scope: %{}
                 })

        assert {:error, %AshHooks.Errors.Unknown.ReplayStoreUnavailable{}} =
                 ingest(:protected, body)

        refute_receive :decoded
        refute_receive {:handled, _}
        assert [%{id: id, replay_identity: nil}] = Ash.read!(Ledger, tenant: "a")
        assert id == legacy.id
      end

      test "compaction requires the ledger opt-in and the maintenance actor" do
        assert {:error, :replay_retention_not_enabled} =
                 Ingress.compact_replay_receipts(LegacyLedger, tenant: "a", older_than: future())

        assert {:ok, :created, receipt} = ingest(:protected, ~s({"id":"requires-policy"}))

        assert {:error, error} =
                 Ingress.compact_replay_receipts(Ledger, tenant: "a", older_than: future())

        assert %Ash.Error.Forbidden{} = Ash.Error.to_error_class(error)
        assert [%{replay_identity: :retained, payload: payload}] = Ash.read!(Ledger, tenant: "a")
        assert payload == receipt.payload
      end

      test "legacy identity adoption refuses a protected declaration" do
        assert {:error, :protected_admission_required} =
                 Ingress.plan_legacy_identity_adoption(Ledger, :protected, tenant: "a")
      end

      test "protected reservation requires authorization by the ledger policy" do
        body = ~s({"type":"processed"})

        assert {:error, %AshHooks.Errors.Unknown.ReplayStoreUnavailable{}} =
                 ingest(:protected, body, actor: nil)

        refute_receive {:handled, _}
        assert [] = Ash.read!(Ledger, tenant: "a")
        assert {:ok, :created, %{status: :processed}} = ingest(:protected, body)
      end

      test "cutover rotates away the old signing material and retains legacy rows until ordinary prune" do
        body = ~s({"type":"processed","id":"from-before-cutover"})

        assert {:ok, :created, legacy} =
                 ingest(:protected, body, resource: LegacyLedger, key_slot: :legacy)

        assert %{replay_identity: nil} = Ash.get!(Ledger, legacy.id, tenant: "a")

        assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
                 ingest(:protected, body, key_slot: :legacy)

        assert {:ok, :created, protected} = ingest(:protected, body)
        assert {:ok, 1} = Ingress.prune(Ledger, tenant: "a", older_than: future())
        assert [%{id: id, replay_identity: :retained}] = Ash.read!(Ledger, tenant: "a")
        assert id == protected.id
      end

      test "retirement refuses admission and package prune cannot release protected rows" do
        body = ~s({"type":"processed","id":"before-retirement"})
        assert {:ok, :created, accepted} = ingest(:protected, body)

        assert {:error, %AshHooks.Errors.Invalid.UnknownSource{}} =
                 ingest(:protected, body, resource: RetiredLedger)

        if Code.ensure_loaded?(Plug.Test) do
          assert http_ingest(RetiredLedger, body).status == 404
        end

        assert {:error, :protected_admission_required} =
                 Ingress.ingest_delivery(RetiredLedger, %{name: :protected, tenant: "a"})

        assert {:ok, 1} =
                 Ingress.compact_replay_receipts(RetiredLedger,
                   actor: @service_actor,
                   tenant: "a",
                   older_than: future()
                 )

        assert {:ok, 0} = Ingress.prune(RetiredLedger, tenant: "a", older_than: future())

        assert [%{id: id, replay_identity: :compacted} = retained] =
                 Ash.read!(RetiredLedger, tenant: "a")

        assert id == accepted.id

        assert {:error, _} =
                 Ash.destroy(retained, action: :prune, authorize?: false, tenant: "a")

        # Privileged release follows irreversible closure and namespace retirement.
        Repo.query!(
          "DELETE FROM #{@table} WHERE provider = 'protected' AND replay_identity = 'compacted'"
        )

        assert Ash.read!(RetiredLedger, tenant: "a") == []

        assert {:error, %AshHooks.Errors.Invalid.UnknownSource{}} =
                 ingest(:protected, body, resource: RetiredLedger)
      end
    end
  end

  defp entry_point_cases() do
    quote do
      test "low-level admission cannot use the protected receipt writer" do
        assert {:error, :protected_admission_required} =
                 Ingress.ingest_delivery(Ledger, %{name: :protected, tenant: "a"})
      end

      if Code.ensure_loaded?(Plug.Test) do
        test "unsigned topic headers cannot select another replay fence" do
          body = ~s({"type":"processed","id":"http"})

          for topic <- ["first", "forged"] do
            assert http_ingest(Ledger, body, [{"x-topic", topic}]).status == 200
          end

          assert_receive {:handled, %{"id" => "http"}}
          refute_receive {:handled, _}
          assert [_single] = Ash.read!(Ledger, tenant: "a")
        end
      end

      test "a low-level legacy caller cannot redirect a write into signed admission" do
        assert {:error, :protected_admission_required} =
                 Ingress.ingest_delivery(Ledger, %{name: "protected", tenant: "a"})

        input = %{
          name: :legacy,
          external_event_id: "legacy-id",
          type_string: nil,
          digest: "legacy-digest",
          payload: %{},
          tenant: "a",
          scope: %{"external_event_id" => "overridden", provider: :protected},
          replay_protection: :durable_identity
        }

        assert {:ok, true, row} = Ingress.ingest_delivery(Ledger, input)
        assert row.provider == :legacy
        assert row.external_event_id == "legacy-id"
        assert row.replay_identity == nil
      end
    end
  end

  defp row_security_cases(layer) do
    quote do
      if unquote(layer) == :postgres do
        test "forced row security confines cleanup and denies direct deletion of a protected row" do
          body = ~s({"type":"processed","id":"overlapping"})
          assert {:ok, :created, first} = ingest(:protected, body)
          assert {:ok, :created, second} = ingest(:protected, body, tenant: "b")
          assert first.external_event_id == second.external_event_id

          role = "#{@table}_operator"
          Repo.query!("CREATE ROLE #{role} NOLOGIN")

          on_exit(fn ->
            Repo.query!("ALTER TABLE #{@table} DISABLE ROW LEVEL SECURITY")
            Repo.query!("DROP POLICY IF EXISTS replay_scope ON #{@table}")
            Repo.query!("DROP POLICY IF EXISTS legacy_delete ON #{@table}")
            Repo.query!("REVOKE SELECT, UPDATE, DELETE ON #{@table} FROM #{role}")
            Repo.query!("DROP ROLE #{role}")
          end)

          Repo.query!("GRANT SELECT, UPDATE, DELETE ON #{@table} TO #{role}")
          Repo.query!("ALTER TABLE #{@table} ENABLE ROW LEVEL SECURITY")
          Repo.query!("ALTER TABLE #{@table} FORCE ROW LEVEL SECURITY")

          Repo.query!("""
          CREATE POLICY replay_scope ON #{@table} AS RESTRICTIVE
          USING (tenant_slug = current_setting('ash_hooks.test_replay_tenant', true))
          """)

          Repo.query!("""
          CREATE POLICY legacy_delete ON #{@table} AS RESTRICTIVE FOR DELETE
          USING (replay_identity IS NULL)
          """)

          Repo.query!("CREATE POLICY receipt_access ON #{@table} USING (true)")
          on_exit(fn -> Repo.query!("DROP POLICY receipt_access ON #{@table}") end)

          assert {:ok, :protected} =
                   Repo.transaction(fn ->
                     Repo.query!("SET LOCAL ROLE #{role}")
                     Repo.query!("SELECT set_config('ash_hooks.test_replay_tenant', 'a', true)")

                     assert {:ok, 1} = compact()
                     assert [] = Ash.read!(Ledger, tenant: "b")
                     assert %{num_rows: 0} = Repo.query!("DELETE FROM #{@table}")
                     assert [%{replay_identity: :compacted}] = Ash.read!(Ledger, tenant: "a")
                     :protected
                   end)

          assert [%{replay_identity: :retained}] = Ash.read!(Ledger, tenant: "b")
        end
      end
    end
  end

  defp ingress_helpers() do
    quote do
      def route(_conn), do: {:ok, %{source: :protected, tenant: "a", actor: @service_actor}}

      def respond(outcome) do
        send(self(), {:host_response, outcome})
        :default
      end

      defp http_ingest(resource, body, headers \\ []) do
        options =
          AshHooks.Plug.init(
            resource: resource,
            resolve: {__MODULE__, :route, []},
            respond: {__MODULE__, :respond, []}
          )

        conn =
          Plug.Test.conn("POST", "/hooks", body)
          |> Plug.Conn.put_req_header("x-signature", signature(body, "a", :current))

        headers
        |> Enum.reduce(conn, fn {name, value}, conn ->
          Plug.Conn.put_req_header(conn, name, value)
        end)
        |> AshHooks.Plug.call(options)
      end

      defp ingest(source, body, opts \\ []) do
        tenant = Keyword.get(opts, :tenant, "a")
        slot = Keyword.get(opts, :key_slot, if(source == :legacy, do: :legacy, else: :current))
        signature = signature(body, Keyword.get(opts, :signing_tenant, tenant), slot)
        headers = [{"x-signature", signature} | Keyword.get(opts, :headers, [])]

        resource = Keyword.get(opts, :resource, Ledger)
        actor = Keyword.get(opts, :actor, @service_actor)

        Ingress.ingest(resource, source, body, %{
          tenant: tenant,
          actor: actor,
          signature: signature,
          headers: headers
        })
      end

      defp signature(body, tenant, slot) do
        :hmac
        |> :crypto.mac(:sha256, unquote(__MODULE__).key(tenant, slot), body)
        |> Base.encode16(case: :lower)
      end

      defp future, do: DateTime.add(DateTime.utc_now(), 3_600)

      defp compact(cutoff \\ future()) do
        Ingress.compact_replay_receipts(Ledger,
          actor: @service_actor,
          tenant: "a",
          older_than: cutoff
        )
      end
    end
  end

  def current(tenant), do: {:ok, key(tenant, :current)}
  def previous(tenant), do: {:ok, key(tenant, :previous)}
  def legacy(tenant), do: {:ok, key(tenant, :legacy)}

  defp admission_actions(true),
    do: [:ingest_protected, :record_protected_malformed, :compact_replay_receipt]

  defp admission_actions(false), do: [:ingest]

  def check_storage(query, repo, table) do
    if Process.get(:check_replay_storage) do
      send(self(), :checked_replay_storage)
      repo.query!("SELECT 1 FROM #{table} LIMIT 1")
    end

    query
  end

  def key(tenant, slot) do
    :crypto.hash(:sha256, :erlang.term_to_binary({tenant, slot}))
    |> Base.encode16(case: :lower)
  end

  def limit_capacity!(:sqlite, repo, table) do
    repo.query!("""
    CREATE TRIGGER #{table}_capacity BEFORE INSERT ON #{table}
    WHEN NEW.replay_identity IS NOT NULL AND EXISTS (
      SELECT 1 FROM #{table} WHERE replay_identity IS NOT NULL
    )
    BEGIN
      SELECT RAISE(ABORT, 'protected receipt capacity exhausted');
    END
    """)

    fn -> repo.query!("DROP TRIGGER IF EXISTS #{table}_capacity") end
  end

  def limit_capacity!(:postgres, repo, table) do
    repo.query!("""
    CREATE FUNCTION #{table}_capacity() RETURNS trigger AS $$
    BEGIN
      IF NEW.replay_identity IS NOT NULL AND EXISTS (
        SELECT 1 FROM #{table} WHERE replay_identity IS NOT NULL
      ) THEN
        RAISE EXCEPTION 'protected receipt capacity exhausted' USING ERRCODE = '53100';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    repo.query!("""
    CREATE TRIGGER #{table}_capacity BEFORE INSERT ON #{table}
    FOR EACH ROW EXECUTE FUNCTION #{table}_capacity()
    """)

    fn -> repo.query!("DROP FUNCTION IF EXISTS #{table}_capacity() CASCADE") end
  end
end

defmodule AshHooks.DurableReplayTest do
  use AshHooks.DurableReplayTest.Cases,
    layer: :sqlite,
    repo: AshHooks.Test.Repo,
    table: "durable_replay_test"
end

defmodule AshHooks.DurableReplayPostgresTest do
  use AshHooks.DurableReplayTest.Cases,
    layer: :postgres,
    repo: AshHooks.TestPostgres.Repo,
    table: "durable_replay_pg_test"
end
