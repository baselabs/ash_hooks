if Code.ensure_loaded?(Plug.Conn) do
  defmodule AshHooks.PlugTest do
    use ExUnit.Case, async: false
    import Plug.Conn
    import ExUnit.CaptureLog

    alias AshHooks.Errors.Invalid.{
      InvalidSignature,
      MalformedPayload,
      NoWebhookSecret,
      StaleTimestamp
    }

    defmodule Provider do
      use AshHooks.Provider,
        verify: [algorithm: :hmac_sha256, signature: {:header, "x-signature"}]

      @impl true
      defdelegate handle_event(type, payload), to: AshHooks.CountingProvider
    end

    defmodule TimestampProvider do
      use AshHooks.Provider,
        verify: [
          algorithm: :hmac_sha256,
          signature: {:header, "x-signature"},
          timestamp: {:header, "x-time"},
          signed_input: [:timestamp, ".", :body]
        ]

      @impl true
      defdelegate handle_event(type, payload), to: AshHooks.CountingProvider
    end

    defmodule UrlProvider do
      use AshHooks.Provider,
        verify: [
          algorithm: :hmac_sha256,
          signature: {:header, "x-signature"},
          signed_input: [:method, ".", :url, ".", :body]
        ]

      @impl true
      defdelegate handle_event(type, payload), to: AshHooks.CountingProvider
    end

    defmodule ProtocolProvider do
      use AshHooks.Provider,
        verify: [algorithm: :hmac_sha256, signature: {:header, "x-signature"}]

      @impl true
      def handshake(request) do
        send(self(), {:handshake, request})

        case request.query_params do
          %{"challenge" => challenge} -> {:respond, 202, [{"x-challenge", "yes"}], challenge}
          _ -> :deliver
        end
      end

      @impl true
      def response(outcome) do
        send(self(), {:provider_response, outcome})

        case outcome do
          {:ok, _, %{payload: %{"answer" => true}}} ->
            {201, [{"x-provider", "yes"}], "accepted"}

          {:ok, _, %{payload: %{"busy" => true}}} ->
            {503, [{"retry-after", "3"}], "protocol busy"}

          _ ->
            :default
        end
      end

      @impl true
      defdelegate handle_event(type, payload), to: AshHooks.CountingProvider
    end

    defmodule ConnectionProvider do
      use AshHooks.Provider,
        verify: [algorithm: :hmac_sha256, signature: {:header, "x-signature"}]

      @impl true
      def webhook_secret_scope, do: :per_connection

      @impl true
      def webhook_signing_secret(connection, tenant) do
        send(self(), {:connection, connection, tenant})
        {:ok, connection.secret}
      end

      @impl true
      defdelegate handle_event(type, payload), to: AshHooks.CountingProvider
    end

    # A hand-written provider on the default `:header` signature source: it
    # reads only the host-supplied `ctx.signature`, never request headers.
    defmodule HeaderProvider do
      @behaviour AshHooks.Provider

      @impl true
      def verify_signature(raw_body, ctx, secret),
        do:
          AshHooks.Provider.default_verify_signature(
            raw_body,
            ctx.signature,
            secret,
            :hmac_sha256
          )

      @impl true
      def parse_event_type(_payload), do: {:ok, :webhook}

      @impl true
      defdelegate handle_event(type, payload), to: AshHooks.CountingProvider
    end

    # Each substrate uses the same declarations and assertions. Tenancy and scope
    # participate in the real database's unique index, not a separate seen cache.
    for {name, layer, repo, table, tenant?} <- [
          {AshHooks.PlugTest.Ledger, AshSqlite.DataLayer, AshHooks.Test.Repo, "plug_ledger",
           false},
          {AshHooks.PlugTest.TenantLedger, AshSqlite.DataLayer, AshHooks.Test.Repo,
           "plug_tenant_ledger", true},
          {AshHooks.PlugTest.PostgresLedger, AshPostgres.DataLayer, AshHooks.TestPostgres.Repo,
           "plug_ledger", false},
          {AshHooks.PlugTest.PostgresTenantLedger, AshPostgres.DataLayer,
           AshHooks.TestPostgres.Repo, "plug_tenant_ledger", true}
        ] do
      storage =
        if layer == AshSqlite.DataLayer do
          quote do
            sqlite do
              table unquote(table)
              repo(unquote(repo))
            end
          end
        else
          quote do
            postgres do
              table unquote(table)
              repo(unquote(repo))
            end
          end
        end

      tenancy =
        if tenant? do
          quote do
            attributes do
              attribute :org_id, :string, allow_nil?: false
              attribute :endpoint_id, :string, allow_nil?: false
            end

            multitenancy do
              strategy :attribute
              attribute :org_id
            end

            inbound_delivery do
              scope_identity [:endpoint_id]
            end
          end
        end

      declarations =
        for {source, provider} <- [
              orders: AshHooks.PlugTest.Provider,
              timestamped: AshHooks.PlugTest.TimestampProvider,
              url: AshHooks.PlugTest.UrlProvider,
              protocol: AshHooks.PlugTest.ProtocolProvider,
              connection: AshHooks.PlugTest.ConnectionProvider,
              host_signed: AshHooks.PlugTest.HeaderProvider
            ] do
          quote do
            inbound unquote(source) do
              provider(unquote(provider))
              secret {AshHooks.PlugTest, :secret, []}
            end
          end
        end

      Module.create(
        name,
        quote do
          use Ash.Resource,
            domain: AshHooks.PlugTest.Domain,
            data_layer: unquote(layer),
            extensions: [AshHooks, AshHooks.InboundDelivery]

          unquote(storage)
          unquote(tenancy)

          actions do
            defaults [:read]
          end

          webhooks do
            unquote_splicing(declarations)

            inbound :paused do
              provider(AshHooks.PlugTest.Provider)
              secret {AshHooks.PlugTest, :secret, []}
              paused(fn -> true end)
            end

            inbound :secretless do
              provider(AshHooks.PlugTest.Provider)
              secret fn -> {:error, :no_webhook_secret} end
            end
          end
        end,
        Macro.Env.location(__ENV__)
      )
    end

    alias __MODULE__.{Ledger, PostgresLedger, PostgresTenantLedger, TenantLedger}

    defmodule Domain do
      use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

      resources do
        resource AshHooks.PlugTest.Ledger
        resource AshHooks.PlugTest.TenantLedger
        resource AshHooks.PlugTest.PostgresLedger
        resource AshHooks.PlugTest.PostgresTenantLedger
      end
    end

    defmodule Router do
      use Plug.Router
      plug(:match)
      plug(:dispatch)

      match _ do
        AshHooks.Plug.call(conn, AshHooks.Plug.init(conn.private.plug_options))
      end
    end

    defmodule ParsedRouter do
      use Plug.Router

      plug(Plug.Parsers,
        parsers: [:json],
        json_decoder: Jason,
        body_reader: {AshHooks.BodyReader, :read_body, [only: ["/webhooks"]]}
      )

      plug(:match)
      plug(:dispatch)
      forward("/webhooks", to: Router)
    end

    defmodule ConsumedRouter do
      use Plug.Router
      plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
      plug(:match)
      plug(:dispatch)
      forward("/webhooks", to: Router)
    end

    defmodule HostBodyReader do
      def read_body(conn, options) do
        {:ok, bytes, conn} = Plug.Conn.read_body(conn, options)
        {:ok, bytes, AshHooks.BodyReader.put_raw_body(conn, bytes)}
      end
    end

    defmodule HostParsedRouter do
      use Plug.Router

      plug(Plug.Parsers,
        parsers: [:json],
        json_decoder: Jason,
        body_reader: {HostBodyReader, :read_body, []}
      )

      plug(:match)
      plug(:dispatch)
      forward("/webhooks", to: Router)
    end

    # A real HTTP server for the interoperability tests: Bandit on loopback,
    # an endpoint-style Plug.Parsers with the body reader, and the plug mounted
    # by `forward` as a host would mount it.
    defmodule HttpRouter do
      use Plug.Router

      plug(Plug.Parsers,
        parsers: [:json],
        pass: ["*/*"],
        json_decoder: Jason,
        body_reader: {AshHooks.BodyReader, :read_body, [only: ["/webhooks"]]}
      )

      plug(:match)
      plug(:dispatch)

      forward("/webhooks/orders",
        to: AshHooks.Plug,
        init_opts: [resource: AshHooks.PlugTest.Ledger, source: :orders]
      )

      forward("/webhooks/small",
        to: AshHooks.Plug,
        init_opts: [resource: AshHooks.PlugTest.Ledger, source: :orders, length: 16]
      )

      forward("/webhooks/host-signed",
        to: AshHooks.Plug,
        init_opts: [
          resource: AshHooks.PlugTest.Ledger,
          source: :host_signed,
          signature_header: "x-signature"
        ]
      )
    end

    # Real TCP reads for transport failures. Responses use Plug.Test's normal
    # response recorder; no signature, provider, ledger or database is replaced.
    defmodule SocketAdapter do
      def read_req_body(state, options) do
        send(self(), :socket_body_read)
        length = min(state.remaining, Keyword.get(options, :length, 8_000_000))

        case :gen_tcp.recv(state.socket, length, Keyword.get(options, :read_timeout, 15_000)) do
          {:ok, chunk} ->
            remaining = state.remaining - byte_size(chunk)
            tag = if remaining == 0, do: :ok, else: :more
            {tag, chunk, %{state | remaining: remaining}}

          {:error, _} = error ->
            error
        end
      end

      defdelegate send_resp(state, status, headers, body), to: Plug.Adapters.Test.Conn
    end

    @secret "plug-test-secret"
    def secret, do: {:ok, @secret}
    def public_uri(_conn, value), do: value

    def resolve(conn, result) do
      send(self(), {:resolved, conn.path_info})
      result
    end

    def respond(outcome, result) do
      send(self(), {:host_response, outcome})
      result
    end

    def refuse(reason, result) do
      send(self(), {:refused, reason})
      result
    end

    defp body(extra \\ %{}), do: Jason.encode!(Map.merge(%{"id" => "event-1"}, extra))

    defp sign(input),
      do: :crypto.mac(:hmac, :sha256, @secret, input) |> Base.encode16(case: :lower)

    defp request(raw, opts \\ []) do
      Plug.Test.conn("POST", "/webhooks/orders", raw)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("content-length", Integer.to_string(byte_size(raw)))
      |> put_req_header("x-signature", sign(raw))
      |> put_private(:plug_options, Keyword.merge([resource: Ledger, source: :orders], opts))
    end

    defp run(conn, router \\ Router), do: router.call(conn, router.init([]))

    defp assert_response(conn, status, body \\ "") do
      assert conn.status == status
      assert conn.resp_body == body
      assert conn.halted
      assert conn.state == :sent
      conn
    end

    setup_all do
      repos =
        [AshHooks.Test.Repo] ++
          if System.get_env("ASH_HOOKS_POSTGRES") == "1",
            do: [AshHooks.TestPostgres.Repo],
            else: []

      for repo <- repos, tenant? <- [false, true] do
        table = if tenant?, do: "plug_tenant_ledger", else: "plug_ledger"

        {id, payload, time} =
          if repo == AshHooks.Test.Repo,
            do: {"TEXT", "TEXT", "TEXT"},
            else: {"UUID", "JSONB", "TIMESTAMPTZ"}

        scope = if tenant?, do: ", org_id TEXT NOT NULL, endpoint_id TEXT NOT NULL", else: ""
        keys = if tenant?, do: ", org_id, endpoint_id", else: ""

        repo.query!("""
        CREATE TABLE #{table} (
          id #{id} PRIMARY KEY, provider TEXT NOT NULL, external_event_id TEXT NOT NULL,
          external_event_type TEXT, payload #{payload} NOT NULL, payload_digest TEXT NOT NULL,
          status TEXT NOT NULL, fencing_token INTEGER NOT NULL DEFAULT 0,
          lease_expires_at #{time}, error_class TEXT, attempts INTEGER NOT NULL DEFAULT 0#{scope}
        )
        """)

        repo.query!(
          "CREATE UNIQUE INDEX #{table}_unique_ingest_index ON #{table} (provider, external_event_id#{keys})"
        )
      end

      on_exit(fn ->
        for repo <- repos,
            table <- ["plug_ledger", "plug_tenant_ledger"],
            do: repo.query!("DROP TABLE #{table}")
      end)

      {:ok, repos: repos}
    end

    setup %{repos: repos} do
      for repo <- repos,
          table <- ["plug_ledger", "plug_tenant_ledger"],
          do: repo.query!("DELETE FROM #{table}")

      AshHooks.CountingProvider.put_sink(self())
      AshHooks.CountingProvider.put_outcome(:ok)
      on_exit(&AshHooks.CountingProvider.cleanup/0)
      :ok
    end

    for {ledger, tenant_ledger, substrate} <- [
          {Ledger, TenantLedger, :sqlite},
          {PostgresLedger, PostgresTenantLedger, :postgres}
        ] do
      if substrate == :postgres, do: @tag(:postgres)

      test "#{substrate}: cached and directly read bytes process once through routers" do
        ledger = unquote(ledger)

        for router <- [ParsedRouter, Router] do
          raw = body(%{"router" => inspect(router)})
          request(raw, resource: ledger) |> run(router) |> assert_response(200)
          assert_receive {:handled, :webhook, _}
          request(raw, resource: ledger) |> run(router) |> assert_response(200)
          refute_receive {:handled, _, _}
        end

        rows = Ash.read!(ledger, authorize?: false)
        assert length(rows) == 2
        assert Enum.all?(rows, &(&1.status == :processed))
      end

      if substrate == :postgres, do: @tag(:postgres)

      test "#{substrate}: resolver threads tenant, scope and connection into the ledger" do
        ledger = unquote(tenant_ledger)
        # Attacker partition first: identical bodies must remain independent.
        for tenant <- ["org-b", "org-a"], endpoint <- ["endpoint-2", "endpoint-1"] do
          result =
            {:ok,
             %{
               source: :connection,
               tenant: tenant,
               scope: %{endpoint_id: endpoint},
               connection: %{secret: @secret}
             }}

          request(body())
          |> put_private(:plug_options,
            resource: ledger,
            resolve: {__MODULE__, :resolve, [result]}
          )
          |> run()
          |> assert_response(200)

          assert_receive {:resolved, ["webhooks", "orders"]}
          assert_receive {:connection, %{secret: @secret}, ^tenant}
          assert_receive {:handled, :webhook, _}
        end

        for tenant <- ["org-a", "org-b"] do
          rows = Ash.read!(ledger, tenant: tenant, authorize?: false)
          assert Enum.sort(Enum.map(rows, & &1.endpoint_id)) == ["endpoint-1", "endpoint-2"]
          assert Enum.all?(rows, &(&1.org_id == tenant and &1.status == :processed))
        end
      end
    end

    test "bad signature is 400 without handling or persisting" do
      request(body()) |> put_req_header("x-signature", "bad") |> run() |> assert_response(400)
      assert Ash.read!(Ledger, authorize?: false) == []
      refute_receive {:handled, _, _}
    end

    test "a signed stale timestamp is 400 without handling" do
      raw = body()
      time = Integer.to_string(System.system_time(:second) - 600)

      request(raw, source: :timestamped)
      |> put_req_header("x-time", time)
      |> put_req_header("x-signature", sign(time <> "." <> raw))
      |> run()
      |> assert_response(400)

      assert Ash.read!(Ledger, authorize?: false) == []
      refute_receive {:handled, _, _}
    end

    test "retryable and permanent handler outcomes control acknowledgment" do
      for {kind, status} <- [retry: 500, permanent: 200] do
        AshHooks.CountingProvider.put_outcome({:error, kind, :failure})
        request(body(%{"kind" => to_string(kind)})) |> run() |> assert_response(status)
        assert_receive {:handled, :webhook, _}
      end

      assert Enum.sort(Enum.map(Ash.read!(Ledger, authorize?: false), & &1.status)) ==
               [:failed_permanent, :failed_retryable]
    end

    test "paused, missing-secret and unknown sources are 503" do
      for source <- [:paused, :secretless, :unknown] do
        request(body(), source: source) |> run() |> assert_response(503)
      end

      assert Ash.read!(Ledger, authorize?: false) == []
      refute_receive {:handled, _, _}
    end

    test "resolver refusals bypass both response policies and all writes" do
      for {reason, status} <- [not_found: 404, unavailable: 503] do
        request(body())
        |> put_private(:plug_options,
          resource: Ledger,
          resolve: {__MODULE__, :resolve, [{:error, reason}]},
          respond: {__MODULE__, :respond, [{299, [], "wrong"}]}
        )
        |> run()
        |> assert_response(status)

        assert_receive {:resolved, _}
        refute_receive {:host_response, _}
      end

      assert Ash.read!(Ledger, authorize?: false) == []
    end

    test "resolver can select a source without additional context" do
      request(body())
      |> put_private(:plug_options,
        resource: Ledger,
        resolve: {__MODULE__, :resolve, [{:ok, %{source: :orders}}]}
      )
      |> run()
      |> assert_response(200)

      assert_receive {:resolved, _}
      assert_receive {:handled, :webhook, _}
    end

    test "method refusal includes allow and bypasses response policies" do
      conn =
        request(body(),
          source: :protocol,
          methods: ["POST", "PUT"],
          respond: {__MODULE__, :respond, [{299, [], "wrong"}]}
        )
        |> Map.put(:method, "DELETE")
        |> run()
        |> assert_response(405)

      assert get_resp_header(conn, "allow") == ["POST, PUT"]
      assert_receive {:handshake, %{method: "DELETE"}}
      refute_receive {:provider_response, _}
      refute_receive {:host_response, _}
      assert Ash.read!(Ledger, authorize?: false) == []
    end

    test "explicitly allowed non-POST method delivers" do
      request(body(), methods: ["PUT"])
      |> Map.put(:method, "PUT")
      |> run()
      |> assert_response(200)
    end

    test "oversized direct body is 413 without an ingest" do
      request(body(), length: 4) |> run() |> assert_response(413)
      assert Ash.read!(Ledger, authorize?: false) == []
      refute_receive {:handled, _, _}
    end

    test "cached bytes take priority and the plug length applies only to its own reads" do
      request(body(), length: 1) |> run(ParsedRouter) |> assert_response(200)
    end

    test "direct reads accumulate chunks with a total length bound" do
      raw = body(%{"padding" => String.duplicate("x", 100)})

      request(raw, length: byte_size(raw), read_length: 8, read_timeout: 1000)
      |> run()
      |> assert_response(200)

      assert_receive {:handled, :webhook, %{"padding" => padding}}
      assert byte_size(padding) == 100
    end

    test "parsed body without BodyReader fails closed with one actionable error" do
      log = capture_log(fn -> request(body()) |> run(ConsumedRouter) |> assert_response(500) end)
      assert length(Regex.scan(~r/\[error\]/, log)) == 1
      assert log =~ "body_reader: {AshHooks.BodyReader, :read_body, []}"
      assert Ash.read!(Ledger, authorize?: false) == []
      refute_receive {:handled, _, _}
    end

    test "an empty body without a positive declared length is still a delivery" do
      request("") |> run() |> assert_response(200)

      for value <- [nil, "invalid", "-1"] do
        conn = request("") |> delete_req_header("content-length")
        conn = if value, do: put_req_header(conn, "content-length", value), else: conn
        run(conn) |> assert_response(200)
      end
    end

    test "public base URI preserves path and query without using the internal authority" do
      for suffix <- ["", "?q=a%2Fb&q=2"] do
        path = "/webhooks/orders" <> suffix
        raw = body(%{"suffix" => suffix})

        conn =
          request(raw, source: :url, request_uri: "https://public.example.test///")
          |> Map.merge(%{
            host: "internal.invalid",
            port: 4000,
            scheme: :http,
            query_string: String.trim_leading(suffix, "?")
          })
          |> put_req_header(
            "x-signature",
            sign("POST.https://public.example.test" <> path <> "." <> raw)
          )

        conn |> run() |> assert_response(200)

        conn
        |> put_req_header(
          "x-signature",
          sign("POST.http://internal.invalid:4000" <> path <> "." <> raw)
        )
        |> run()
        |> assert_response(400)
      end
    end

    test "request URI MFA receives conn and its configured arguments" do
      uri = "https://public.example.test/exact?value=1"
      raw = body()

      request(raw, source: :url, request_uri: {__MODULE__, :public_uri, [uri]})
      |> put_req_header("x-signature", sign("POST." <> uri <> "." <> raw))
      |> run()
      |> assert_response(200)
    end

    test "no configured URI supplies no URL to URL-dependent verification" do
      request(body(), source: :url) |> run() |> assert_response(400)
    end

    test "handshake answers a challenge before method or signature verification" do
      conn =
        request("", source: :protocol)
        |> Map.merge(%{method: "GET", query_string: "challenge=hello%20world&nested[x]=1"})
        |> delete_req_header("x-signature")
        |> run()
        |> assert_response(202, "hello world")

      assert get_resp_header(conn, "x-challenge") == ["yes"]

      assert_receive {:handshake,
                      %{
                        method: "GET",
                        raw_body: "",
                        query_params: %{"challenge" => "hello world", "nested" => %{"x" => "1"}},
                        headers: headers
                      }}

      assert headers == conn.req_headers
      assert Ash.read!(Ledger, authorize?: false) == []
      refute_receive {:handled, _, _}
      refute_receive {:provider_response, _}
    end

    test "provider response wins over host response and receives the exact ingest outcome" do
      conn =
        request(body(%{"answer" => true}),
          source: :protocol,
          respond: {__MODULE__, :respond, [{299, [], "wrong"}]}
        )
        |> run()
        |> assert_response(201, "accepted")

      assert get_resp_header(conn, "x-provider") == ["yes"]
      assert_receive {:provider_response, {:ok, :created, row}}
      assert row.status == :processed
      assert [stored] = Ash.read!(Ledger, authorize?: false)
      assert row.id == stored.id
      refute_receive {:host_response, _}
    end

    test "provider default allows host response and host default falls back to mapping" do
      conn =
        request(body(),
          source: :protocol,
          respond: {__MODULE__, :respond, [{202, [{"x-host", "yes"}], "queued"}]}
        )
        |> run()
        |> assert_response(202, "queued")

      assert get_resp_header(conn, "x-host") == ["yes"]
      assert_receive {:provider_response, outcome}
      assert_receive {:host_response, ^outcome}

      request(body(), source: :protocol, respond: {__MODULE__, :respond, [:default]})
      |> run()
      |> assert_response(200)

      assert_receive {:host_response, {:ok, :duplicate, %{status: :processed}}}
    end

    test "provider default without host policy falls back and errors reach host unchanged" do
      request(body(), source: :protocol) |> run() |> assert_response(200)
      assert_receive {:provider_response, {:ok, :created, _}}

      request(body(), respond: {__MODULE__, :respond, [:default]})
      |> put_req_header("x-signature", "bad")
      |> run()
      |> assert_response(400)

      assert_receive {:host_response, {:error, %InvalidSignature{}}}
    end

    test "provider dispatch treats absent callbacks as unimplemented" do
      refute function_exported?(Provider, :handshake, 1)
      refute function_exported?(Provider, :response, 1)
      assert AshHooks.Provider.handshake(Provider, %{}) == :deliver
      assert AshHooks.Provider.response(Provider, {:error, :storage}) == :default
      assert AshHooks.Provider.handshake(AshHooks.PlugTest.Unloaded, %{}) == :deliver
      assert AshHooks.Provider.response(AshHooks.PlugTest.Unloaded, :anything) == :default
    end

    test "public default response covers terminal, retryable, verification and infrastructure outcomes" do
      opts = AshHooks.Plug.init(resource: Ledger, source: :orders)

      for status <- [:processed, :failed_permanent, :superseded], tag <- [:created, :duplicate] do
        assert AshHooks.Plug.default_response({:ok, tag, %{status: status}}, opts) ==
                 {200, [], ""}
      end

      for status <- [:received, :processing, :failed_retryable] do
        assert AshHooks.Plug.default_response({:ok, :duplicate, %{status: status}}, opts) ==
                 {500, [], ""}
      end

      for error <- [
            InvalidSignature.exception([]),
            StaleTimestamp.exception([]),
            MalformedPayload.exception([])
          ] do
        assert AshHooks.Plug.default_response({:error, error}, opts) == {400, [], ""}
      end

      for error <- [:source_paused, NoWebhookSecret.exception([]), :storage_failure, :anything] do
        for seconds <- [60, 180] do
          assert AshHooks.Plug.default_response(
                   {:error, error},
                   Keyword.put(opts, :retry_after, seconds)
                 ) ==
                   {503, [{"retry-after", Integer.to_string(seconds)}], ""}
        end
      end
    end

    test "refusal policy shapes each refusal while status and required headers remain owned by the plug" do
      host = {[{"x-refused", "yes"}, {"allow", "DELETE"}, {"retry-after", "999"}], "refused"}

      for {reason, status, options, router, method} <- [
            {:not_found, 404, [resolve: {__MODULE__, :resolve, [{:error, :not_found}]}], Router,
             "POST"},
            {:unavailable, 503, [resolve: {__MODULE__, :resolve, [{:error, :unavailable}]}],
             Router, "POST"},
            {:method_not_allowed, 405, [source: :protocol], Router, "GET"},
            {:too_large, 413, [source: :protocol, length: 2], Router, "POST"},
            {:body_consumed, 500, [source: :protocol], ConsumedRouter, "POST"}
          ] do
        log =
          capture_log(fn ->
            options =
              [
                resource: Ledger,
                retry_after: 120,
                refuse: {__MODULE__, :refuse, [host]},
                respond: {__MODULE__, :respond, [{299, [], "wrong"}]}
              ] ++ options

            conn =
              request(body())
              |> put_private(:plug_options, options)
              |> Map.put(:method, method)
              |> run(router)
              |> assert_response(status, "refused")

            assert get_resp_header(conn, "x-refused") == ["yes"]
            if status == 405, do: assert(get_resp_header(conn, "allow") == ["POST"])
            if status == 503, do: assert(get_resp_header(conn, "retry-after") == ["120"])
          end)

        if reason == :body_consumed, do: assert(log =~ "body_reader:")
        assert_receive {:refused, ^reason}
        refute_receive {:provider_response, _}
        refute_receive {:host_response, _}
      end

      assert Ash.read!(Ledger, authorize?: false) == []
    end

    test "default refusal policy preserves empty body and required headers" do
      for seconds <- [60, 120] do
        conn =
          request(body())
          |> put_private(:plug_options,
            resource: Ledger,
            resolve: {__MODULE__, :resolve, [{:error, :unavailable}]},
            retry_after: seconds,
            refuse: {__MODULE__, :refuse, [:default]}
          )
          |> run()
          |> assert_response(503)

        assert get_resp_header(conn, "retry-after") == [Integer.to_string(seconds)]
        assert_receive {:refused, :unavailable}
      end

      conn =
        request(body(), refuse: {__MODULE__, :refuse, [:default]})
        |> Map.put(:method, "GET")
        |> run()
        |> assert_response(405)

      assert get_resp_header(conn, "allow") == ["POST"]
      assert_receive {:refused, :method_not_allowed}
    end

    test "default ingest failures and resolver unavailability carry configured retry-after" do
      for config <- [[], [retry_after: 120]] do
        expected = Integer.to_string(Keyword.get(config, :retry_after, 60))

        for source <- [:paused, :secretless, :unknown] do
          conn = request(body(), [source: source] ++ config) |> run() |> assert_response(503)
          assert get_resp_header(conn, "retry-after") == [expected]
        end

        conn =
          request(body())
          |> put_private(
            :plug_options,
            [resource: Ledger, resolve: {__MODULE__, :resolve, [{:error, :unavailable}]}] ++
              config
          )
          |> run()
          |> assert_response(503)

        assert get_resp_header(conn, "retry-after") == [expected]
      end
    end

    test "storage failure uses the default 503 with retry-after" do
      repo = AshHooks.Test.Repo
      repo.query!("ALTER TABLE plug_ledger RENAME TO plug_ledger_unavailable")

      try do
        capture_log(fn ->
          for options <- [[], [retry_after: 120]] do
            conn = request(body(), options) |> run() |> assert_response(503)

            assert get_resp_header(conn, "retry-after") ==
                     [Integer.to_string(Keyword.get(options, :retry_after, 60))]
          end
        end)
      after
        repo.query!("ALTER TABLE plug_ledger_unavailable RENAME TO plug_ledger")
      end
    end

    test "a host policy owns the headers on its 503" do
      conn =
        request(body(),
          retry_after: 120,
          respond: {__MODULE__, :respond, [{503, [{"retry-after", "7"}], "busy"}]}
        )
        |> run()
        |> assert_response(503, "busy")

      assert get_resp_header(conn, "retry-after") == ["7"]
    end

    test "a provider policy owns the headers on its 503" do
      conn =
        request(body(%{"busy" => true}), source: :protocol, retry_after: 120)
        |> run()
        |> assert_response(503, "protocol busy")

      assert get_resp_header(conn, "retry-after") == ["3"]
    end

    test "a closed TCP body read fails unavailable without an ingest" do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_tcp.close(listener) end)
      {:ok, {_, port}} = :inet.sockname(listener)
      {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      on_exit(fn -> :gen_tcp.close(client) end)
      {:ok, socket} = :gen_tcp.accept(listener)
      on_exit(fn -> :gen_tcp.close(socket) end)
      :ok = :gen_tcp.close(client)

      conn = request(body(), retry_after: 120)
      {_, state} = conn.adapter
      conn = %{conn | adapter: {SocketAdapter, Map.merge(state, %{socket: socket, remaining: 1})}}
      conn = run(conn) |> assert_response(503)
      assert get_resp_header(conn, "retry-after") == ["120"]
      assert Ash.read!(Ledger, authorize?: false) == []
      refute_receive {:handled, _, _}
    end

    test "a host body reader supplies exact bytes without a second read" do
      raw = " \n" <> body() <> "\t"
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_tcp.close(listener) end)
      {:ok, {_, port}} = :inet.sockname(listener)
      {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      on_exit(fn -> :gen_tcp.close(client) end)
      {:ok, socket} = :gen_tcp.accept(listener)
      on_exit(fn -> :gen_tcp.close(socket) end)
      :ok = :gen_tcp.send(client, raw)
      :ok = :gen_tcp.close(client)

      conn = request(raw, length: 1)
      {_, state} = conn.adapter

      conn = %{
        conn
        | adapter: {SocketAdapter, Map.merge(state, %{socket: socket, remaining: byte_size(raw)})}
      }

      conn = run(conn, HostParsedRouter) |> assert_response(200)
      assert AshHooks.BodyReader.raw_body(conn) == raw
      assert_receive :socket_body_read
      refute_receive :socket_body_read
      assert_receive {:handled, :webhook, %{"id" => "event-1"}}
      assert [%{status: :processed}] = Ash.read!(Ledger, authorize?: false)
    end

    test "a header-source provider gets its signature from the configured header" do
      opts = [source: :host_signed, signature_header: "x-signature"]
      request(body(), opts) |> run() |> assert_response(200)
      assert_receive {:handled, :webhook, %{"id" => "event-1"}}
      assert [%{status: :processed}] = Ash.read!(Ledger, authorize?: false)
    end

    test "without a signature header a header-source provider fails closed" do
      request(body(), source: :host_signed) |> run() |> assert_response(400)
      refute_receive {:handled, _, _}
      assert Ash.read!(Ledger, authorize?: false) == []
    end

    test "a missing or repeated signature header fails closed" do
      opts = [source: :host_signed, signature_header: "x-signature"]
      raw = body()

      missing = request(raw, opts) |> delete_req_header("x-signature")

      repeated =
        request(raw, opts)
        |> Map.update!(:req_headers, &(&1 ++ [{"x-signature", sign(raw)}]))

      for conn <- [missing, repeated] do
        conn |> run() |> assert_response(400)
      end

      refute_receive {:handled, _, _}
      assert Ash.read!(Ledger, authorize?: false) == []
    end

    test "a resolver's signature header overrides the configured one" do
      result = {:ok, %{source: :host_signed, signature_header: "x-signature"}}

      request(body())
      |> put_private(:plug_options,
        resource: Ledger,
        resolve: {__MODULE__, :resolve, [result]},
        signature_header: "x-other"
      )
      |> run()
      |> assert_response(200)

      assert_receive {:handled, :webhook, _}
    end

    test "over real HTTP, the mounted plug verifies, ingests and answers" do
      server =
        start_supervised!(
          {Bandit, plug: HttpRouter, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

      post = fn path, raw, type, headers ->
        url = ~c"http://127.0.0.1:#{port}#{path}"
        headers = for {name, value} <- headers, do: {to_charlist(name), to_charlist(value)}

        {:ok, {{_, status, _}, response_headers, _body}} =
          :httpc.request(:post, {url, headers, to_charlist(type), raw}, [], body_format: :binary)

        {status, response_headers}
      end

      # Parsed by the endpoint parser: the plug uses the cached exact bytes.
      parsed = " " <> body(%{"via" => "parser"}) <> "\n"

      assert {200, _} =
               post.("/webhooks/orders", parsed, "application/json", [
                 {"x-signature", sign(parsed)}
               ])

      assert_receive {:handled, :webhook, %{"via" => "parser"}}

      # An unparsed content type: the plug reads the body itself.
      direct = Jason.encode!(%{"id" => "event-2", "via" => "direct"})

      assert {200, _} =
               post.("/webhooks/orders", direct, "application/octet-stream", [
                 {"x-signature", sign(direct)}
               ])

      assert_receive {:handled, :webhook, %{"via" => "direct"}}

      # The same delivery again is acknowledged without a second handler run.
      assert {200, _} =
               post.("/webhooks/orders", direct, "application/octet-stream", [
                 {"x-signature", sign(direct)}
               ])

      refute_receive {:handled, _, _}

      # A provider on the default :header source, its signature named by the route.
      signed = body(%{"via" => "header"})

      assert {200, _} =
               post.("/webhooks/host-signed", signed, "application/json", [
                 {"x-signature", sign(signed)}
               ])

      assert_receive {:handled, :webhook, %{"via" => "header"}}

      # Refusals write nothing.
      tampered = body(%{"id" => "event-3"})

      assert {400, _} =
               post.("/webhooks/orders", tampered, "application/json", [
                 {"x-signature", sign("other")}
               ])

      oversized = Jason.encode!(%{"id" => "event-4", "padding" => String.duplicate("x", 64)})

      assert {413, _} =
               post.("/webhooks/small", oversized, "application/octet-stream", [
                 {"x-signature", sign(oversized)}
               ])

      {:ok, {{_, 405, _}, headers, _}} =
        :httpc.request(:get, {~c"http://127.0.0.1:#{port}/webhooks/orders", []}, [], [])

      assert {~c"allow", ~c"POST"} in headers
      refute_receive {:handled, _, _}

      rows = Ash.read!(Ledger, authorize?: false)
      assert length(rows) == 3
      assert Enum.all?(rows, &(&1.status == :processed))
    end

    test "init validates shapes without loading or introspecting the resource" do
      opts = AshHooks.Plug.init(resource: AshHooks.PlugTest.NotCompiledYet, source: :orders)
      assert opts[:resource] == AshHooks.PlugTest.NotCompiledYet
      assert opts[:methods] == ["POST"]
      assert opts[:length] == 8_000_000
      assert opts[:retry_after] == 60
    end

    test "init rejects both or neither source and resolver" do
      assert_raise ArgumentError, ~r/exactly one/, fn -> AshHooks.Plug.init(resource: Ledger) end

      assert_raise ArgumentError, ~r/exactly one/, fn ->
        AshHooks.Plug.init(resource: Ledger, source: :orders, resolve: {__MODULE__, :resolve, []})
      end
    end

    test "init rejects invalid option shapes" do
      for opts <- [
            [resource: "ledger"],
            [source: "orders"],
            [resolve: fn _ -> :not_found end],
            [request_uri: 42],
            [request_uri: {__MODULE__, :public_uri, :bad}],
            [methods: ["post"]],
            [methods: [:POST]],
            [length: 0],
            [read_length: -1],
            [read_timeout: -1],
            [respond: :bad],
            [refuse: :bad],
            [refuse: {__MODULE__, :refuse, :bad}],
            [retry_after: 0],
            [retry_after: -1],
            [signature_header: "X-Signature"],
            [signature_header: ""],
            [signature_header: :x_signature],
            [unknown: true]
          ] do
        assert_raise Spark.Options.ValidationError, fn ->
          AshHooks.Plug.init(Keyword.merge([resource: Ledger, source: :orders], opts))
        end
      end

      assert_raise Spark.Options.ValidationError, fn -> AshHooks.Plug.init(source: :orders) end
    end
  end
else
  defmodule AshHooks.PlugAbsentTest do
    use ExUnit.Case, async: true

    test "the optional adapter and Plug are absent" do
      refute Code.ensure_loaded?(Plug.Conn)
      refute Code.ensure_loaded?(AshHooks.Plug)
      refute Code.ensure_loaded?(AshHooks.BodyReader)
    end
  end
end
