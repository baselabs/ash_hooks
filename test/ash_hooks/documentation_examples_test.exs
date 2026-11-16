if Code.ensure_loaded?(Phoenix.Endpoint) do
  defmodule AshHooks.DocumentationExamplesTest do
    # The shipped documentation's mounting examples, compiled and run as written.
    #
    # Each marked block (`<!-- tested: name -->` on the line before its fence) is
    # read from the document, parsed, and placed unchanged in a real Phoenix
    # endpoint and router: `plug` calls in the endpoint, `forward` calls in the
    # router, `defmodule`s beside them. Every example lives in its own namespace,
    # so the document's `MyApp.*` names resolve to that namespace's application
    # (ledger, provider, endpoint lookup) through Elixir's nested-module aliases,
    # and the examples never collide. Requests go over real HTTP to a Bandit
    # server on loopback, into a real SQLite ledger.
    #
    use ExUnit.Case, async: false

    alias AshHooks.Test.Repo

    alias AshHooks.Test.Documentation, as: Docs

    @secret "documentation-example-secret"
    @examples %{
      "readme-fixed-source" => {"readme-fixed-source", "readme-fixed-source"},
      "verify-any-sender-signature-header" =>
        {"readme-install-endpoint", "verify-any-sender-signature-header"}
    }

    def secret, do: {:ok, @secret}

    test "README: a fixed source in a Phoenix endpoint and router" do
      port = start_example("readme-fixed-source", ReadmeFixed, ledger(sources: [payments: :hmac]))
      raw = event("fixed")

      assert {200, _} =
               post(port, "/webhooks/payments", raw, [
                 {"x-payments-signature", structured_sign(raw)}
               ])

      assert {400, _} =
               post(port, "/webhooks/payments", raw, [
                 {"x-payments-signature", structured_sign("x")}
               ])

      assert [%{status: :processed}] = rows(ReadmeFixed)
    end

    test "verify-any-sender: a header-source provider named by signature_header" do
      port =
        start_example(
          "verify-any-sender-signature-header",
          VerifyAnySender,
          ledger(sources: [billing: :header])
        )

      raw = event("billing")
      assert {200, _} = post(port, "/webhooks/billing", raw, [{"x-billing-signature", sign(raw)}])
      assert {400, _} = post(port, "/webhooks/billing", raw, [])
      assert [%{status: :processed}] = rows(VerifyAnySender)
    end

    # ── the documents ──

    defp example(name) do
      case Docs.ast(name) do
        {:__block__, _, expressions} -> expressions
        expression -> [expression]
      end
    end

    # ── the application each example is mounted in ──

    defp start_example(name, label, ledger) do
      {endpoint_block, router_block} = Map.fetch!(@examples, name)
      namespace = Module.concat([__MODULE__, label])
      endpoint = Module.concat([namespace, MyAppWeb, Endpoint])

      Application.put_env(:ash_hooks, endpoint,
        adapter: Bandit.PhoenixAdapter,
        http: [ip: {127, 0, 0, 1}, port: 0],
        server: true,
        secret_key_base: String.duplicate("k", 64)
      )

      plugs = for {:plug, _, _} = expression <- example(endpoint_block), do: expression
      router = example(router_block)
      forwards = for {:forward, _, _} = expression <- router, do: expression
      modules = for {:defmodule, _, _} = expression <- router, do: expression
      table = "doc_" <> Macro.underscore(label)

      quote do
        defmodule unquote(namespace) do
          unquote_splicing(fixtures(ledger, table))
          unquote_splicing(modules)

          defmodule MyAppWeb.Router do
            use Phoenix.Router
            unquote_splicing(forwards)
          end

          defmodule MyAppWeb.Endpoint do
            use Phoenix.Endpoint, otp_app: :ash_hooks
            unquote_splicing(plugs)
            plug(MyAppWeb.Router)
          end
        end
      end
      |> lexical()
      |> Code.eval_quoted()

      create_table(table, ledger)
      start_supervised!(endpoint)
      {:ok, {_ip, port}} = endpoint.server_info(:http)
      port
    end

    defp lexical(ast) do
      Macro.prewalk(ast, fn
        {:__aliases__, meta, parts} -> {:__aliases__, Keyword.delete(meta, :alias), parts}
        other -> other
      end)
    end

    defp ledger(options), do: Map.new(options)

    defp fixtures(ledger, table) do
      providers = for {source, kind} <- ledger.sources, do: provider_fixture(source, kind)

      inbounds =
        for {source, module, _} <- providers do
          quote do
            inbound unquote(source) do
              provider(unquote(module))
              secret {AshHooks.DocumentationExamplesTest, :secret, []}
            end
          end
        end

      tenancy = tenancy_fixture(ledger[:tenant])
      scope = scope_fixture(ledger[:scope])

      Enum.map(providers, &elem(&1, 2)) ++
        [
          quote do
            defmodule MyApp.WebhookLedger do
              use Ash.Resource,
                domain: MyApp.Domain,
                data_layer: AshSqlite.DataLayer,
                extensions: [AshHooks, AshHooks.InboundDelivery]

              sqlite do
                table unquote(table)
                repo(AshHooks.Test.Repo)
              end

              unquote(tenancy)
              unquote(scope)

              actions do
                defaults [:read]
              end

              webhooks do
                (unquote_splicing(inbounds))
              end
            end

            defmodule MyApp.Domain do
              use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

              resources do
                resource MyApp.WebhookLedger
              end
            end
          end
        ]
    end

    defp provider_fixture(source, kind) do
      module =
        {:__aliases__, [],
         [:MyApp, :Webhooks, source |> to_string() |> Macro.camelize() |> String.to_atom()]}

      body =
        case kind do
          :hmac ->
            {:defmodule, _, [_module, [do: provider]]} = Docs.ast("readme-payments-provider")
            provider

          :header ->
            quote do
              @behaviour AshHooks.Provider

              @impl true
              def verify_signature(raw, ctx, secret),
                do:
                  AshHooks.Provider.default_verify_signature(
                    raw,
                    ctx.signature,
                    secret,
                    :hmac_sha256
                  )

              @impl true
              def parse_event_type(_payload), do: {:ok, :webhook}

              @impl true
              defdelegate handle_event(type, payload), to: AshHooks.Provider.Event, as: :build
            end
        end

      {source, module, quote(do: defmodule(unquote(module), do: unquote(body)))}
    end

    defp tenancy_fixture(nil), do: nil

    defp tenancy_fixture(attribute) do
      quote do
        attributes do
          attribute unquote(attribute), :string, allow_nil?: false
        end

        multitenancy do
          strategy :attribute
          attribute unquote(attribute)
        end
      end
    end

    defp scope_fixture(nil), do: nil

    defp scope_fixture(attribute) do
      quote do
        attributes do
          attribute unquote(attribute), :string, allow_nil?: false
        end

        inbound_delivery do
          scope_identity [unquote(attribute)]
        end
      end
    end

    defp create_table(table, ledger) do
      extra =
        for attribute <- [ledger[:tenant], ledger[:scope]],
            attribute,
            do: ", #{attribute} TEXT NOT NULL"

      keys = for attribute <- [ledger[:tenant], ledger[:scope]], attribute, do: ", #{attribute}"

      Repo.query!("""
      CREATE TABLE #{table} (
        id TEXT PRIMARY KEY, provider TEXT NOT NULL, external_event_id TEXT NOT NULL,
        external_event_type TEXT, payload TEXT NOT NULL, payload_digest TEXT NOT NULL,
        status TEXT NOT NULL, fencing_token INTEGER NOT NULL DEFAULT 0,
        lease_expires_at TEXT, error_class TEXT, attempts INTEGER NOT NULL DEFAULT 0#{Enum.join(extra)}
      )
      """)

      Repo.query!(
        "CREATE UNIQUE INDEX #{table}_unique_ingest_index ON #{table} (provider, external_event_id#{Enum.join(keys)})"
      )

      on_exit(fn -> Repo.query!("DROP TABLE #{table}") end)
    end

    # ── requests ──

    defp event(via), do: Jason.encode!(%{"id" => "event-" <> via, "via" => via})

    defp structured_sign(raw) do
      timestamp = Integer.to_string(System.system_time(:second))
      signature = sign(timestamp <> "." <> raw)
      "t=#{timestamp},v1=#{signature}"
    end

    defp sign(raw), do: :crypto.mac(:hmac, :sha256, @secret, raw) |> Base.encode16(case: :lower)

    defp post(port, path, raw, headers) do
      headers = for {name, value} <- headers, do: {to_charlist(name), to_charlist(value)}
      request = {~c"http://127.0.0.1:#{port}#{path}", headers, ~c"application/json", raw}

      {:ok, {{_, status, _}, response_headers, _}} =
        :httpc.request(:post, request, [], body_format: :binary)

      {status, response_headers}
    end

    defp rows(label, tenant \\ nil) do
      ledger = Module.concat([__MODULE__, label, MyApp, WebhookLedger])
      Ash.read!(ledger, tenant: tenant, authorize?: false)
    end
  end
end

defmodule AshHooks.DocumentationContentTest do
  use ExUnit.Case, async: false

  alias AshHooks.Test.Documentation, as: Docs

  @providers ~w(module-provider-orders readme-payments-provider upgrade-shop-provider verify-orders-provider
    verify-shop-provider verify-prefixed-provider-in-application
    verify-encoded-key-provider-in-application verify-structured-provider-in-application
    verify-standard-provider-in-application verify-request-provider-in-application
    verify-crm-provider verify-fields-provider verify-date-provider
    verify-migrating-provider verify-classification-provider verify-custom-provider)
  @tag :postgres
  test "the row-security repository example binds and clears real tenant transactions" do
    namespace = Docs.namespace("row-security-repo-binding")
    Docs.eval("row-security-repo-binding", namespace)
    repo = Module.concat(namespace, MyApp.Repo)
    resource = Module.concat(namespace, BindingResource)

    Application.put_env(:my_app, repo, AshHooks.TestPostgres.Repo.config())
    on_exit(fn -> Application.delete_env(:my_app, repo) end)
    start_supervised!(repo)

    Code.compile_quoted(
      quote do
        defmodule unquote(resource) do
          use Ash.Resource,
            data_layer: AshPostgres.DataLayer,
            domain: nil

          postgres do
            table "row_security_binding_example"
            repo(unquote(repo))
          end
        end
      end
    )

    for tenant <- [nil, "tenant_b", 42, :tenant_a] do
      expected = if is_nil(tenant), do: nil, else: to_string(tenant)

      assert {:ok, :ok} =
               Ash.transact(
                 resource,
                 fn ->
                   assert %{rows: [[^expected]]} =
                            repo.query!(
                              "SELECT nullif(current_setting('my_app.tenant', true), '')"
                            )

                   :ok
                 end,
                 tenant: tenant
               )

      assert %{rows: [[nil]]} =
               repo.query!("SELECT nullif(current_setting('my_app.tenant', true), '')")
    end

    assert {:error, _} =
             Ash.transact(
               resource,
               fn ->
                 assert %{rows: [["tenant_b"]]} =
                          repo.query!("SELECT current_setting('my_app.tenant', true)")

                 repo.rollback(:intentional_rollback)
               end,
               tenant: "tenant_b"
             )

    assert %{rows: [[nil]]} =
             repo.query!("SELECT nullif(current_setting('my_app.tenant', true), '')")
  end

  for name <- @providers do
    test "runs #{name} with actual cryptographic signatures" do
      name = unquote(name)
      module = Docs.compile(name)
      {body, ctx, secret} = Docs.vector(name)
      assert :ok = module.verify_signature(body, ctx, secret)

      assert {:error, :invalid_signature} =
               module.verify_signature(body, %{ctx | headers: %{}}, secret)

      unless name == "verify-fields-provider" do
        assert {:error, :invalid_signature} = module.verify_signature(body <> " ", ctx, secret)
      end

      {:ok, payload} = Jason.decode(body)
      assert {:ok, type} = module.parse_event_type(payload)
      assert {:ok, %AshHooks.Provider.Event{type: ^type}} = module.handle_event(type, payload)

      if name == "verify-fields-provider" do
        assert {:ok, "signed-1"} = module.event_identity(payload)
        altered = Jason.encode!(%{payload | "event_id" => "changed"})
        assert {:error, :invalid_signature} = module.verify_signature(altered, ctx, secret)
      end
    end
  end

  test "RSA and JWS recipe fragments verify actual public-key signatures" do
    for {name, jws?} <- [
          {"verify-rsa-provider-in-application", false},
          {"verify-jws-provider-in-application", true}
        ] do
      module = Docs.compile(name)
      {body, ctx, key} = Docs.rsa_vector(jws?)
      assert :ok = module.verify_signature(body, ctx, key)
      assert {:error, :invalid_signature} = module.verify_signature(body <> "x", ctx, key)

      if jws? do
        assert {:ok, payload} = module.decode_payload(body)
        assert {:ok, identity} = module.event_identity(payload)
        assert is_binary(identity)
      end
    end
  end

  test "decoder examples keep direct calls and honor the request decoder" do
    for name <- ["upgrade-json-decoder-provider", "verify-json-policy-provider"] do
      provider = Docs.compile(name)
      body = ~s({"original":true})
      assert {:ok, %{"original" => true}} = provider.decode_payload(body)
      sentinel = %{"from_request_decoder" => true}
      decoder = fn ^body -> {:ok, sentinel} end

      assert {:ok, ^sentinel} = AshHooks.Provider.decode_payload(provider, body, nil, decoder)
    end
  end

  test "the key guide issues, rolls, reissues and disposes through real custody" do
    cases = AshHooks.Test.KeyIssuingCases
    namespace = Docs.namespace("key-custody-endpoint-lifecycle")
    ctx = cases.setup_all(namespace, AshSqlite.DataLayer, AshHooks.Test.RegistryRepo, "docs_keys")
    cases.clean(ctx)

    {_, binding} =
      Docs.eval("key-custody-endpoint-lifecycle", namespace,
        endpoint_resource: ctx.endpoint,
        registry_resource: ctx.registry,
        tenant: 17
      )

    endpoint = Ash.reload!(binding[:endpoint], tenant: 17, authorize?: false)
    assert endpoint.previous_secret_ref == nil
    assert endpoint.secret_kind == {:standard_webhooks, :v1}

    assert {:ok, signature} =
             ctx.custodian.sign(endpoint.secret_ref, "17", endpoint.secret_kind, "input")

    "whsec_" <> encoded = binding[:replacement_disclosure]
    assert signature == :crypto.mac(:hmac, :sha256, Base.decode64!(encoded), "input")

    assert Enum.frequencies_by(Ash.read!(ctx.registry, tenant: 17, authorize?: false), & &1.state) ==
             %{attached: 1, destroyed: 2}
  end

  test "form recipe signs sorted form fields and checks the JSON body digest" do
    module = Docs.compile("verify-form-provider")
    secret = :crypto.strong_rand_bytes(32)
    url = "https://hooks.example.com/form"
    body = "b=2&a=1"
    signature = :crypto.mac(:hmac, :sha, secret, url <> "a1b2") |> Base.encode64()
    ctx = %{request_uri: url, headers: %{"x-form-signature" => signature}}
    assert :ok = module.verify_signature(body, ctx, secret)
    assert {:error, :invalid_signature} = module.verify_signature("b=3&a=1", ctx, secret)

    body = ~s({"id":"event-1"})
    digest = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    url = url <> "?body_digest=" <> digest
    signature = :crypto.mac(:hmac, :sha, secret, url) |> Base.encode64()
    ctx = %{ctx | request_uri: url, headers: %{"x-form-signature" => signature}}
    assert :ok = module.verify_signature(body, ctx, secret)
    assert {:error, :invalid_signature} = module.verify_signature(body <> " ", ctx, secret)
  end

  test "public URL function uses application configuration and the original path/query" do
    namespace = Docs.namespace("verify-public-url-in-application")
    code = Docs.ast("verify-public-url-in-application")

    quote do
      defmodule unquote(namespace) do
        unquote(code)
      end
    end
    |> Docs.lexical()
    |> Code.compile_quoted()

    previous = Application.get_env(:my_app, :public_webhook_base_url)
    Application.put_env(:my_app, :public_webhook_base_url, "https://hooks.example.com")
    on_exit(fn -> restore_env(:public_webhook_base_url, previous) end)
    conn = %{request_path: "/hooks/orders", query_string: "account=1"}
    assert namespace.public_url(conn) == "https://hooks.example.com/hooks/orders?account=1"
  end

  test "upgrade constraints and both string-counting configurations evaluate as written" do
    for {name, requirement} <- [
          {"upgrade-dependency-1-0-4", "~> 1.0.4"},
          {"upgrade-dependency-1-0", "~> 1.0"}
        ] do
      assert {{:ash_hooks, ^requirement}, _} = Code.eval_quoted(Docs.ast(name))
    end

    code = "import Config\n" <> Docs.block("upgrade-string-config-in-application").code
    assert [ash: [default_string_length_count: :mixed]] = Config.Reader.eval!("config.exs", code)
    assert Enum.count(Regex.scan(~r/default_string_length_count:/, code)) == 2
  end

  test "upgrade source and adoption fragments run against a scoped tenant ledger" do
    namespace = Docs.namespace("upgrade-application")
    source = Docs.ast("upgrade-source-in-application")

    quote do
      defmodule unquote(namespace) do
        defmodule MyApp.Repo do
          use AshSqlite.Repo, otp_app: :ash_hooks
          @impl true
          def write_transactions?, do: true
          @impl true
          def min_sqlite_version, do: %Version{major: 3, minor: 54, patch: 1}
        end

        defmodule MyApp.Webhooks.ExistingSource do
          use AshHooks.Provider,
            verify: [algorithm: :hmac_sha256, signature: {:header, "x-signature"}]

          @impl true
          def event_identity(%{"id" => id}), do: {:ok, id}
        end

        defmodule MyApp.InboundLedger do
          use Ash.Resource,
            domain: MyApp.Domain,
            data_layer: AshSqlite.DataLayer,
            extensions: [AshHooks, AshHooks.InboundDelivery]

          sqlite do
            repo(MyApp.Repo)
            table "documentation_upgrade_ledger"
          end

          attributes do
            attribute :org_id, :string, allow_nil?: false
            attribute :account_id, :string, allow_nil?: false
            timestamps()
          end

          multitenancy do
            strategy :attribute
            attribute :org_id
          end

          inbound_delivery do
            scope_identity [:account_id]
          end

          actions do
            defaults [:read]
          end

          unquote(source)
        end

        defmodule MyApp.Domain do
          use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

          resources do
            resource MyApp.InboundLedger
          end
        end
      end
    end
    |> Docs.lexical()
    |> Code.compile_quoted()

    repo = Module.concat([namespace, MyApp, Repo])
    database = Path.join(System.tmp_dir!(), "ash_hooks_docs_#{Ash.UUID.generate()}.sqlite3")

    start_supervised!(
      {repo,
       database: database,
       pool_size: 1,
       journal_mode: :wal,
       busy_timeout: 5_000,
       synchronous: :normal}
    )

    on_exit(fn ->
      for suffix <- ["", "-wal", "-shm"], do: File.rm(database <> suffix)
    end)

    repo.query!("""
    CREATE TABLE documentation_upgrade_ledger (
      id TEXT PRIMARY KEY, provider TEXT NOT NULL, external_event_id TEXT NOT NULL,
      external_event_type TEXT, payload TEXT NOT NULL, payload_digest TEXT NOT NULL,
      status TEXT NOT NULL, fencing_token INTEGER NOT NULL DEFAULT 0,
      lease_expires_at TEXT, error_class TEXT, attempts INTEGER NOT NULL DEFAULT 0,
      org_id TEXT NOT NULL, account_id TEXT NOT NULL, inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL
    )
    """)

    repo.query!(
      "CREATE UNIQUE INDEX documentation_upgrade_identity ON documentation_upgrade_ledger (org_id, provider, external_event_id, account_id)"
    )

    ledger = Module.concat([namespace, MyApp, InboundLedger])
    tenant = "org-1"
    account_id = "account-1"

    Ash.Changeset.for_create(
      ledger,
      :ingest,
      %{
        provider: :existing_source,
        external_event_id: "old-body-digest",
        external_event_type: "webhook",
        payload: %{"id" => "canonical-1"},
        payload_digest: "original-body-digest",
        account_id: account_id
      },
      tenant: tenant
    )
    |> Ash.create!(authorize?: false)

    {_value, binding} =
      Docs.eval("upgrade-adoption-in-application", namespace,
        tenant: tenant,
        account_id: account_id
      )

    assert binding[:plan].unresolved == []
    assert binding[:plan].conflicts == []

    assert [%{external_event_id: "canonical-1"}] =
             Ash.read!(ledger, tenant: tenant, authorize?: false)
  end

  test "the inbound source lifecycle example issues and verifies with a real custodian" do
    cases = AshHooks.Test.InboundSourceCases
    namespace = Docs.namespace("inbound-source-lifecycle")

    ctx =
      cases.setup_all(namespace, AshSqlite.DataLayer, AshHooks.Test.RegistryRepo, "docs_source")

    cases.clean(ctx)

    {_, binding} =
      Docs.eval("inbound-source-lifecycle", namespace,
        source_resource: ctx.source,
        source_name: :checked,
        account_id: "account",
        provider_alias: :first,
        tenant: 17
      )

    assert binding[:source].previous_secret_ref == nil
    assert {:ok, _, %{status: :processed}} = cases.ingest(ctx, binding[:next_disclosure])

    assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
             cases.ingest(ctx, binding[:initial_disclosure])
  end

  test "upgrade binding helpers produce declaration and queue identifiers" do
    {_value, binding} = Docs.eval("upgrade-binding-in-application", __MODULE__)
    assert String.starts_with?(binding[:source], "ash_hooks:")
    assert String.starts_with?(binding[:route], "ash_hooks:")
    assert binding[:source] != binding[:route]
  end

  @tag :postgres
  test "the complete guide runs migrations, handlers, dispatch, a persisted queue, and telemetry" do
    namespace = Docs.namespace("get-started-application")
    repo = Module.concat([namespace, MyApp, Repo])
    domain = Module.concat([namespace, MyApp, Domain])
    previous_domains = Application.get_env(:ash_hooks, :ash_domains)
    Application.put_env(:ash_hooks, :ash_domains, [domain])

    on_exit(fn ->
      if is_nil(previous_domains),
        do: Application.delete_env(:ash_hooks, :ash_domains),
        else: Application.put_env(:ash_hooks, :ash_domains, previous_domains)
    end)

    quote do
      defmodule unquote(namespace) do
        unquote(Docs.ast("get-started-resources-in-application"))
        unquote(Docs.ast("get-started-worker-in-application"))
      end
    end
    |> Docs.lexical()
    |> Code.compile_quoted()

    config = AshHooks.TestPostgres.Repo.config()
    previous_repo_config = Application.get_env(:my_app, repo)
    Application.put_env(:my_app, repo, config)
    on_exit(fn -> restore_env(repo, previous_repo_config) end)
    start_supervised!({repo, config})
    migration = Module.concat(namespace, Migration)
    change = Docs.ast("get-started-migration-in-application")

    quote do
      defmodule unquote(migration) do
        use Ecto.Migration

        def change do
          unquote(change)
        end
      end
    end
    |> Docs.lexical()
    |> Code.compile_quoted()

    [[migration_table]] = repo.query!("SELECT to_regclass('public.schema_migrations')::text").rows
    :ok = Ecto.Migrator.up(repo, 3_100_001, migration, log: false)
    oban_prefix = "documentation_examples_oban"
    oban_migration = Module.concat(namespace, ObanMigration)

    quote do
      defmodule unquote(oban_migration) do
        use Ecto.Migration
        def up, do: Oban.Migrations.up(prefix: "documentation_examples_oban")
        def down, do: Oban.Migrations.down(prefix: "documentation_examples_oban")
      end
    end
    |> Code.compile_quoted()

    :ok = Ecto.Migrator.up(repo, 3_100_002, oban_migration, log: false)

    on_exit(fn ->
      Ecto.Migrator.down(AshHooks.TestPostgres.Repo, 3_100_001, migration, log: false)
      Ecto.Migrator.down(AshHooks.TestPostgres.Repo, 3_100_002, oban_migration, log: false)
      AshHooks.TestPostgres.Repo.query!("DROP SCHEMA #{oban_prefix} CASCADE")

      if is_nil(migration_table),
        do: AshHooks.TestPostgres.Repo.query!("DROP TABLE schema_migrations")

      :telemetry.detach("my-ash-hooks")
      Application.delete_env(:my_app, :orders_webhook_secret)
    end)

    oban = Module.concat([namespace, MyApp, Oban])

    start_supervised!(
      {Oban,
       repo: repo,
       name: oban,
       prefix: oban_prefix,
       queues: false,
       plugins: [],
       engine: Oban.Engines.Basic,
       testing: :disabled}
    )

    previous_url = System.get_env("PUBLIC_WEBHOOK_TEST_URL")
    previous_secret = System.get_env("OUTBOUND_WEBHOOK_SECRET")
    System.put_env("PUBLIC_WEBHOOK_TEST_URL", "http://localhost:52871/documentation-example")
    System.put_env("OUTBOUND_WEBHOOK_SECRET", AshHooks.Signing.generate_secret())

    on_exit(fn ->
      restore_system_env("PUBLIC_WEBHOOK_TEST_URL", previous_url)
      restore_system_env("OUTBOUND_WEBHOOK_SECRET", previous_secret)
    end)

    {_value, binding} = Docs.eval("get-started-ingress-in-application", namespace)
    {_value, binding} = Docs.eval("get-started-dispatch-in-application", namespace, binding)
    worker = Module.concat([namespace, MyApp, WebhookDeliveryWorker])
    secrets = Module.concat([namespace, MyApp, Secrets])
    assert {:ok, secret} = secrets.webhook_secret("outbound-main")
    assert secret == System.fetch_env!("OUTBOUND_WEBHOOK_SECRET")
    assert :ok = worker.enqueue(binding[:delivery], binding[:event])
    assert [[1]] = repo.query!("SELECT count(*) FROM #{oban_prefix}.oban_jobs").rows
    assert {:ok, _binding} = Docs.eval("get-started-telemetry-in-application", namespace)
  end

  test "dependency and config fragments execute in their project and configuration contexts" do
    namespace = Docs.namespace("get-started-dependencies-in-project")

    quote do
      defmodule unquote(namespace) do
        unquote(Docs.ast("get-started-dependencies-in-project"))
      end
    end
    |> Code.compile_quoted()

    assert {:ash_hooks, "~> 3.2"} in namespace.deps()
    code = "import Config\n" <> Docs.block("get-started-config-in-application").code

    assert [ash: [default_string_length_count: :codepoints]] =
             Config.Reader.eval!("config.exs", code)
  end

  defp restore_env(key, nil), do: Application.delete_env(:my_app, key)
  defp restore_env(key, value), do: Application.put_env(:my_app, key, value)
  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end

defmodule AshHooks.DocumentationGateTest do
  use ExUnit.Case, async: false

  alias AshHooks.Test.Documentation, as: Docs

  @moduletag skip: not Code.ensure_loaded?(Phoenix.Endpoint)

  test "the parser extracts fenced, indented, nested, and quoted code blocks" do
    for {opening, closing} <- [{"```sql", "```"}, {"~~~sh", "~~~"}, {"```", "```"}] do
      assert [_] = Docs.parse(opening <> "\n:ok\n" <> closing, "guide.md")
    end

    assert [%{language: "elixir", code: ":ok\n"}] = Docs.parse("    :ok\n", "module")
    assert [%{language: "elixir"}] = Docs.parse("- A nested example:\n\n      :ok\n", "module")
    assert [%{language: "sh"}] = Docs.parse("> ```sh\n> true\n> ```\n", "module")
  end

  test "the module destination-policy example compiles and evaluates its decisions" do
    Docs.compile("module-destination-policy")

    policy =
      Module.concat([Docs.namespace("module-destination-policy"), MyApp.WebhookDestinations])

    assert :allow = policy.check("https://partner.internal.example/hook", %{})
    assert :default = policy.check("https://public.example/hook", %{})
    assert :deny = policy.check("file:///etc/hosts", %{})
  end

  test "the contributor configuration evaluates in a real configuration context" do
    code = "import Config\n" <> Docs.block("contributing-string-config").code

    assert [ash: [default_string_length_count: :codepoints]] =
             Config.Reader.eval!("config.exs", code)
  end

  @tag :real_receiver
  @tag timeout: 600_000
  test "every Livebook cell runs headlessly against the candidate archive and real receiver" do
    root = File.cwd!()
    {output, status} = System.cmd("bash", ["scripts/check-package.sh"], stderr_to_stdout: true)
    assert status == 0, output

    archive = Path.join(root, "_build/release/ash_hooks-#{Mix.Project.config()[:version]}.tar")

    {output, status} =
      System.cmd(
        "bash",
        [
          "scripts/run-livebook.sh",
          "documentation/livebooks/get-started.livemd",
          "--archive",
          archive
        ],
        stderr_to_stdout: true,
        env: [
          {"LOCAL_WEBHOOK_TESTER_PORT", System.get_env("ASH_HOOKS_REAL_RECEIVER_PORT", "52871")}
        ]
      )

    assert status == 0, output
    assert output =~ "NOTEBOOK INSTALLED THE CANDIDATE"
    assert output =~ "NOTEBOOK OK:"
  end

  test "SQL splitting preserves quoted semicolons and discards comment-only tails" do
    assert ["SELECT 'a;b'", " SELECT 'it''s;c'", " -- a; comment\nSELECT 2"] =
             Docs.sql_statements(
               "SELECT 'a;b'; SELECT 'it''s;c'; -- a; comment\nSELECT 2; -- tail"
             )
  end

  test "shell blocks execute and command failures raise" do
    block = %{file: "guide.md", line: 1, language: "sh", code: "test -f mix.exs\n"}
    assert :ok = Docs.run!(block, File.cwd!())

    assert_raise RuntimeError, ~r/exited 1/, fn ->
      Docs.run!(%{block | code: "exit 1\n"}, File.cwd!())
    end
  end

  for {label, repo, tags} <- [
        {"SQLite", AshHooks.Test.Repo, []},
        {"PostgreSQL", AshHooks.TestPostgres.Repo, [postgres: true]}
      ] do
    @tag tags
    test "the tenancy backfill runs unchanged and leaves zero NULL tenants on #{label}" do
      repo = unquote(repo)
      tables = ~w(webhook_endpoints webhook_subscriptions inbound_deliveries outbound_deliveries)

      repo.transaction(fn ->
        for table <- tables do
          if table in ~w(webhook_subscriptions outbound_deliveries) do
            repo.query!("CREATE TEMP TABLE #{table} (id TEXT PRIMARY KEY, endpoint_id TEXT)")
            repo.query!("INSERT INTO #{table} VALUES ('row-a', 'row-a'), ('row-b', 'row-b')")
          else
            repo.query!("CREATE TEMP TABLE #{table} (id TEXT PRIMARY KEY, account_id TEXT)")

            repo.query!(
              "INSERT INTO #{table} VALUES ('row-a', 'account-a'), ('row-b', 'account-b')"
            )
          end
        end

        repo.query!(
          "CREATE TEMP TABLE account_tenants (account_id TEXT PRIMARY KEY, org_id TEXT NOT NULL)"
        )

        repo.query!(
          "INSERT INTO account_tenants VALUES ('account-a', 'org-a'), ('account-b', 'org-b')"
        )

        blocks = Docs.blocks("documentation/tutorials/tenancy-adoption-checklist.md")
        for block <- blocks, do: Docs.run!(block, repo)
        [result] = blocks |> List.last() |> Docs.run!(repo)

        assert result.rows == [[0], [0], [0], [0]],
               "the guide's NULL-count gate must return 0 for every table"

        for table <- tables do
          assert [["org-a"], ["org-b"]] ==
                   repo.query!("SELECT org_id FROM #{table} ORDER BY id").rows
        end

        repo.rollback(:documentation_complete)
      end)
    end
  end
end

if Code.ensure_loaded?(AshHooks.Provider) do
  namespace = AshHooks.Test.Documentation.namespace("verify-provider-test-in-application")
  provider = AshHooks.Test.Documentation.ast("verify-orders-provider")
  example = AshHooks.Test.Documentation.ast("verify-provider-test-in-application")

  quote do
    defmodule unquote(namespace) do
      use ExUnit.Case, async: false
      unquote(provider)
      unquote(example)
    end
  end
  |> AshHooks.Test.Documentation.lexical()
  |> Code.compile_quoted()
end
