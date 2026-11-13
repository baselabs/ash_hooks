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
    # The gate: every shipped block that mounts the plug or the body reader must
    # carry a marker this file runs, every marker must match exactly one block,
    # and no module documentation may carry mounting code (it links to the tested
    # README section instead). An example that changes is the example that runs.
    use ExUnit.Case, async: false

    alias AshHooks.Test.Repo

    @shipped ["README.md", "usage-rules.md"] ++
               Path.wildcard("documentation/tutorials/*.md") ++
               Path.wildcard("documentation/livebooks/*.livemd")

    @mounting ~r/forward\s+"[^"]*",\s*AshHooks\.Plug|AshHooks\.BodyReader,\s*:read_body/

    @secret "documentation-example-secret"

    # name => {endpoint block, router block}
    @examples %{
      "readme-fixed-source" => {"readme-fixed-source", "readme-fixed-source"},
      "readme-resolver" => {"readme-fixed-source", "readme-resolver"},
      "get-started-resolver" => {"get-started-endpoint", "get-started-resolver"},
      "verify-any-sender-signature-header" =>
        {"readme-install-endpoint", "verify-any-sender-signature-header"}
    }

    def secret, do: {:ok, @secret}

    setup do
      AshHooks.CountingProvider.put_sink(self())
      AshHooks.CountingProvider.put_outcome(:ok)
      on_exit(&AshHooks.CountingProvider.cleanup/0)
      :ok
    end

    test "every shipped mounting example is marked, and every marker is run" do
      blocks = Enum.flat_map(@shipped, &blocks/1)
      mounting = Enum.filter(blocks, &Regex.match?(@mounting, &1.code))

      for block <- mounting do
        assert block.name,
               "#{block.file}:#{block.line} mounts the plug or the body reader without a " <>
                 "<!-- tested: name --> marker that #{Path.basename(__ENV__.file)} runs"
      end

      run = @examples |> Map.values() |> Enum.flat_map(&Tuple.to_list/1) |> Enum.uniq()
      marked = Enum.flat_map(blocks, &List.wrap(&1.name))

      for name <- run,
          do:
            assert(Enum.count(marked, &(&1 == name)) == 1, "#{name} must mark exactly one block")

      for name <- marked, do: assert(name in run, "#{name} is marked but not run")
    end

    test "no module documentation carries untested mounting code" do
      {:ok, modules} = :application.get_key(:ash_hooks, :modules)

      for module <- modules,
          {:docs_v1, _, _, _, moduledoc, _, docs} <- [Code.fetch_docs(module)],
          %{"en" => text} <- [moduledoc | Enum.map(docs, &elem(&1, 3))] do
        refute Regex.match?(~r/^\s{4,}(forward\s+"|plug\s+Plug\.Parsers)/m, text),
               "#{inspect(module)} documents mounting code; link the tested README section instead"
      end
    end

    test "README: a fixed source in a Phoenix endpoint and router" do
      port = start_example("readme-fixed-source", ReadmeFixed, ledger(sources: [payments: :hmac]))
      raw = event("fixed")
      assert {200, _} = post(port, "/webhooks/payments", raw, [{"x-signature", sign(raw)}])
      assert_receive {:handled, :webhook, %{"via" => "fixed"}}
      assert {400, _} = post(port, "/webhooks/payments", raw, [{"x-signature", sign("x")}])
      assert [%{status: :processed}] = rows(ReadmeFixed)
    end

    test "README: a resolver for a scoped, multitenant ledger" do
      ledger = ledger(sources: [payments: :hmac], tenant: :organization_id, scope: :account_id)
      port = start_example("readme-resolver", ReadmeResolver, ledger)
      raw = event("resolver")

      assert {200, _} =
               post(port, "/webhooks/payments/endpoint-1", raw, [{"x-signature", sign(raw)}])

      assert_receive {:handled, :webhook, %{"via" => "resolver"}}

      assert {404, _} =
               post(port, "/webhooks/payments/missing", raw, [{"x-signature", sign(raw)}])

      assert [%{status: :processed, organization_id: "org-1", account_id: "account-1"}] =
               rows(ReadmeResolver, "org-1")
    end

    test "get-started: the endpoint reader and a scoped resolver" do
      port =
        start_example(
          "get-started-resolver",
          GetStarted,
          ledger(sources: [orders: :hmac], scope: :account_id)
        )

      raw = event("get-started")

      assert {200, _} =
               post(port, "/webhooks/orders/endpoint-1", raw, [{"x-signature", sign(raw)}])

      assert_receive {:handled, :webhook, %{"via" => "get-started"}}
      assert [%{status: :processed, account_id: "account-1"}] = rows(GetStarted)
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
      assert_receive {:handled, :webhook, %{"via" => "billing"}}
      assert {400, _} = post(port, "/webhooks/billing", raw, [])
      assert [%{status: :processed}] = rows(VerifyAnySender)
    end

    # ── the documents ──

    defp blocks(file) do
      file
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> collect(file, nil, nil, [])
    end

    defp collect([], _file, _marker, _open, acc), do: Enum.reverse(acc)

    defp collect([{line, number} | rest], file, marker, nil, acc) do
      cond do
        line == "```elixir" ->
          collect(rest, file, nil, {marker, number, []}, acc)

        match = Regex.run(~r/^<!-- tested: ([a-z0-9-]+) -->$/, line) ->
          collect(rest, file, Enum.at(match, 1), nil, acc)

        true ->
          collect(rest, file, nil, nil, acc)
      end
    end

    defp collect([{"```", _} | rest], file, _marker, {name, number, lines}, acc) do
      block = %{
        file: file,
        line: number,
        name: name,
        code: lines |> Enum.reverse() |> Enum.join("\n")
      }

      collect(rest, file, nil, nil, [block | acc])
    end

    defp collect([{line, _} | rest], file, marker, {name, number, lines}, acc),
      do: collect(rest, file, marker, {name, number, [line | lines]}, acc)

    defp example(name) do
      [block] = @shipped |> Enum.flat_map(&blocks/1) |> Enum.filter(&(&1.name == name))

      case Code.string_to_quoted!(block.code) do
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

    # The wrapper is written with `quote`, whose aliases are hygienic. Drop that
    # marker so they resolve through the namespace's lexical aliases, exactly as
    # the documents' parsed code does.
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

            # The stored-endpoint lookup the resolver examples call.
            defmodule MyApp.Integrations do
              def find_webhook_endpoint(provider, "endpoint-1") do
                {:ok,
                 %{
                   source: String.to_existing_atom(provider),
                   organization_id: "org-1",
                   account_id: "account-1",
                   connection: nil
                 }}
              end

              def find_webhook_endpoint(_provider, _endpoint_id), do: {:error, :not_found}
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
            quote do
              use AshHooks.Provider,
                verify: [algorithm: :hmac_sha256, signature: {:header, "x-signature"}]

              @impl true
              defdelegate handle_event(type, payload), to: AshHooks.CountingProvider
            end

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
              defdelegate handle_event(type, payload), to: AshHooks.CountingProvider
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
