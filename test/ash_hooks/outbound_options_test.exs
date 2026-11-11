defmodule AshHooks.OutboundOptionsTest do
  use ExUnit.Case, async: false
  alias AshHooks.Test.{HttpReceiver, Repo}

  defmodule Endpoint do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.OutboundOptionsTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Endpoint]

    sqlite do
      table("outbound_options_endpoints")
      repo(Repo)
    end

    attributes do
      attribute(:url, :string, allow_nil?: false, public?: true)
    end

    actions do
      defaults([:read, :create, :update])
      default_accept(:*)
    end
  end

  defmodule Delivery do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.OutboundOptionsTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundDelivery]

    sqlite do
      table("outbound_options_deliveries")
      repo(Repo)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(Endpoint)
      resource(Delivery)
    end
  end

  if Code.ensure_loaded?(Oban) do
    defmodule Worker do
      @moduledoc false
      use AshHooks.Worker,
        deliveries: Delivery,
        endpoints: Endpoint,
        secret_resolver: {AshHooks.OutboundOptionsTest, :secret},
        destination_policy: {AshHooks.OutboundOptionsTest, :allow},
        delivery_headers: {AshHooks.OutboundOptionsTest, :headers},
        certificate_pin: {AshHooks.OutboundOptionsTest, :worker_pin},
        retryable_statuses: [409, 425, 500..599],
        http_opts: {AshHooks.OutboundOptionsTest, :worker_http_opts, []}
    end
  end

  @secret "whsec_" <> Base.encode64(:binary.copy(<<42>>, 32))
  @payload ~s({"id":"order_1", "amount":123})
  @tls "test/fixtures/tls/"

  setup_all do
    Repo.query!("""
    CREATE TABLE outbound_options_endpoints (
      id TEXT PRIMARY KEY, url TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'enabled',
      secret_ref TEXT NOT NULL, previous_secret_ref TEXT, legacy_secret_ref TEXT,
      legacy_previous_secret_ref TEXT
    )
    """)

    Repo.query!("""
    CREATE TABLE outbound_options_deliveries (
      id TEXT PRIMARY KEY, event_uuid TEXT NOT NULL, event_type TEXT NOT NULL,
      payload BLOB NOT NULL, endpoint_id TEXT NOT NULL, subscription_id TEXT,
      signing_mode TEXT, status TEXT NOT NULL DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0,
      response_status INTEGER, response_snippet TEXT, last_error TEXT, next_attempt_at TEXT,
      dispatch_source TEXT NOT NULL DEFAULT 'v1:direct:unbound', dispatch_route TEXT NOT NULL DEFAULT 'v1:route:unbound',
      attempt_token TEXT, send_lease_expires_at TEXT, enqueue_token TEXT,
      enqueue_lease_expires_at TEXT, endpoint_snapshot TEXT
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX outbound_options_deliveries_unique_delivery_index ON outbound_options_deliveries (endpoint_id, event_uuid)"
    )

    on_exit(fn ->
      Repo.query!("DROP TABLE outbound_options_deliveries")
      Repo.query!("DROP TABLE outbound_options_endpoints")
    end)

    :ok
  end

  setup do
    {server, port} = HttpReceiver.start()
    on_exit(fn -> :inets.stop(:httpd, server) end)
    %{port: port}
  end

  def secret(_ref), do: {:ok, @secret}

  def headers(row, endpoint, tenant),
    do: %{
      "x-event-type" => row.event_type,
      "x-trace-id" => endpoint.secret_ref <> to_string(tenant)
    }

  def pin(_endpoint, _tenant), do: {:sha256, :binary.copy(<<0>>, 32)}
  def allow(_url, _context), do: :allow
  def worker_pin(%{url: "http:" <> _}, _tenant), do: nil
  def worker_pin(endpoint, tenant), do: pin(endpoint, tenant)

  def worker_http_opts do
    [{:Certificate, ca, _}] = :public_key.pem_decode(File.read!(@tls <> "local-ca.pem"))
    [validate_destination: false, cacerts: [ca]]
  end

  defp row!(port, status, scheme \\ "http") do
    endpoint =
      Ash.create!(
        Endpoint,
        %{url: "#{scheme}://127.0.0.1:#{port}/status/#{status}", secret_ref: "key-reference"},
        authorize?: false
      )

    row =
      Ash.create!(
        Delivery,
        %{
          event_uuid: AshHooks.Signing.generate_msg_id(),
          event_type: "order.created",
          payload: @payload,
          endpoint_id: endpoint.id
        },
        action: :dispatch,
        authorize?: false
      )

    {row, endpoint}
  end

  defp config(opts) do
    Keyword.merge(
      [
        deliveries: Delivery,
        endpoints: Endpoint,
        secret_resolver: {__MODULE__, :secret},
        destination_policy: fn _, _ -> :allow end,
        http_opts: [validate_destination: false],
        max_attempts: 4,
        base_backoff_seconds: 2,
        max_backoff_seconds: 60,
        retry_after_cap_seconds: 100
      ],
      opts
    )
  end

  defp run(row, opts \\ []),
    do:
      AshHooks.Delivery.run(
        %{"endpoint_id" => row.endpoint_id, "event_uuid" => row.event_uuid},
        config(opts)
      )

  defp reload(row), do: Ash.get!(Delivery, row.id, authorize?: false)

  test "opt-in retry statuses honor Retry-After on real 409 and 425; defaults still dead-letter",
       %{port: port} do
    for status <- [409, 425] do
      {row, _} = row!(port, status)
      assert {:snooze, 7} = run(row, retryable_statuses: [408, 409, 425, 429, 500..599])
      assert reload(row).status == :failed_retryable
      assert reload(row).response_status == status
      assert_receive {:http_received, %{body: @payload}}
      {default_row, _} = row!(port, status)
      assert :ok = run(default_row)
      assert reload(default_row).status == :dead_letter
    end
  end

  test "an explicit empty retry list terminalizes 503 while 2xx, redirects, and 410 keep their rules",
       %{port: port} do
    {row, _} = row!(port, 503)
    assert :ok = run(row, retryable_statuses: [])
    assert reload(row).status == :dead_letter

    for status <- [200, 302, 410] do
      {other, endpoint} = row!(port, status)
      assert :ok = run(other, retryable_statuses: [200, 302, 410])
      assert reload(other).status == if(status == 200, do: :succeeded, else: :dead_letter)

      if status == 410,
        do: assert(Ash.get!(Endpoint, endpoint.id, authorize?: false).status == :disabled)
    end
  end

  test "host headers reach the wire beside a verifiable signature and identical payload", %{
    port: port
  } do
    {row, _} = row!(port, 200)
    assert :ok = run(row, delivery_headers: {__MODULE__, :headers})
    assert_receive {:http_received, request}
    assert request.headers["x-event-type"] == "order.created"
    assert request.headers["x-trace-id"] == "key-reference"
    assert request.body == @payload
    assert {:ok, %{id: id}} = AshHooks.Signing.verify(request.body, request.headers, @secret)
    assert id == row.event_uuid
  end

  if Code.ensure_loaded?(Oban) do
    test "the worker refuses an invalid retry status declaration at compilation" do
      on_exit(fn ->
        :code.purge(AshHooks.OutboundOptionsTest.InvalidRetryWorker)
        :code.delete(AshHooks.OutboundOptionsTest.InvalidRetryWorker)
      end)

      assert_raise ArgumentError, ~r/retryable_statuses/, fn ->
        Code.compile_string("""
        defmodule AshHooks.OutboundOptionsTest.InvalidRetryWorker do
          use AshHooks.Worker,
            deliveries: AshHooks.OutboundOptionsTest.Delivery,
            endpoints: AshHooks.OutboundOptionsTest.Endpoint,
            secret_resolver: {AshHooks.OutboundOptionsTest, :secret},
            retryable_statuses: :all
        end
        """)
      end
    end

    test "the generated worker forwards the opt-in policy, header callback, and pin resolver", %{
      port: port
    } do
      {row, _} = row!(port, 409)
      route = AshHooks.OutboundBinding.named_route(AshHooks.OutboundOptionsTest.Worker, :enqueue)
      assert {:ok, row} = AshHooks.Worker.bind_route(row, route, nil)

      assert {:snooze, 7} =
               AshHooks.OutboundOptionsTest.Worker.perform(%Oban.Job{
                 args: %{"endpoint_id" => row.endpoint_id, "event_uuid" => row.event_uuid}
               })

      assert_receive {:http_received, %{headers: %{"x-event-type" => "order.created"}}}

      {unavailable, _} = row!(port, 503)
      assert {:ok, unavailable} = AshHooks.Worker.bind_route(unavailable, route, nil)

      assert {:snooze, 7} =
               AshHooks.OutboundOptionsTest.Worker.perform(%Oban.Job{
                 args: %{
                   "endpoint_id" => unavailable.endpoint_id,
                   "event_uuid" => unavailable.event_uuid
                 }
               })

      assert_receive {:http_received, %{body: @payload}}

      {server, tls_port} =
        HttpReceiver.start(
          socket_type:
            {:ssl,
             [
               certfile: String.to_charlist(@tls <> "server-both-san.pem"),
               keyfile: String.to_charlist(@tls <> "server.key")
             ]}
        )

      on_exit(fn -> :inets.stop(:httpd, server) end)
      {pinned, _} = row!(tls_port, 200, "https")
      assert {:ok, pinned} = AshHooks.Worker.bind_route(pinned, route, nil)

      assert :ok =
               AshHooks.OutboundOptionsTest.Worker.perform(%Oban.Job{
                 args: %{"endpoint_id" => pinned.endpoint_id, "event_uuid" => pinned.event_uuid}
               })

      assert reload(pinned).last_error == "certificate_pin_mismatch"
      refute_received {:http_received, _}
    end
  end

  test "case-insensitive package-owned and framing headers are refused before any request", %{
    port: port
  } do
    for name <- [
          "Webhook-Signature",
          "WEBHOOK-ID",
          "webhook-timestamp",
          "X-Webhook-Signature",
          "Host",
          "Content-Type",
          "Content-Length",
          "Transfer-Encoding",
          "Connection",
          "Trailer",
          "Upgrade"
        ] do
      {row, _} = row!(port, 200)
      assert {:snooze, _} = run(row, delivery_headers: %{name => "override"})
      assert reload(row).last_error == "reserved_delivery_header"
      refute_received {:http_received, _}
    end
  end

  test "malformed headers and crashing callbacks fail before the wire with classified errors", %{
    port: port
  } do
    for {headers, error} <- [
          {%{"x-trace-id" => "bad\r\ninjected: true"}, "invalid_header_value"},
          {fn _, _, _ -> raise "must never reach telemetry" end, "delivery_headers_failed"}
        ] do
      {row, _} = row!(port, 200)
      assert {:snooze, _} = run(row, delivery_headers: headers)
      assert reload(row).last_error == error
      refute_received {:http_received, _}
    end
  end

  test "host-owned webhook metadata headers remain available", %{port: port} do
    {row, _} = row!(port, 200)
    assert :ok = run(row, delivery_headers: %{"X-Webhook-Event" => "order.created"})
    assert_receive {:http_received, %{headers: %{"x-webhook-event" => "order.created"}}}
  end

  test "invalid retry status configuration refuses before claiming or sending", %{port: port} do
    {row, _} = row!(port, 200)

    for statuses <- [:all, ["409"], [99], [600], [1..999], [nil]] do
      assert {:error, :invalid_retryable_statuses} = run(row, retryable_statuses: statuses)
    end

    assert reload(row).attempts == 0
    refute_received {:http_received, _}
  end

  test "a configured pin cannot be silently ignored by another adapter", %{port: port} do
    {row, _} = row!(port, 200)
    assert :ok = run(row, http: AshHooks.Http.Httpc, certificate_pin: false)
    assert reload(row).last_error == "certificate_pin_requires_bounded"
    refute_received {:http_received, _}
  end

  test "function pin selection and failed host callbacks are resolved per attempt without sending on failure",
       %{port: port} do
    {valid, endpoint} = row!(port, 200)
    parent = self()

    assert :ok =
             run(valid,
               certificate_pin: fn selected, tenant ->
                 send(parent, {:pin_selected, selected.id, tenant})
                 nil
               end
             )

    assert_receive {:pin_selected, id, nil}
    assert id == endpoint.id
    assert_receive {:http_received, _}

    for callback <- [fn _, _ -> raise "private" end, fn _, _ -> throw(:private) end] do
      {failed, _} = row!(port, 200)
      assert :ok = run(failed, certificate_pin: callback)
      assert reload(failed).last_error == "certificate_pin_resolution_failed"
      refute_received {:http_received, _}
    end

    {failed, _} = row!(port, 200)
    assert {:snooze, _} = run(failed, delivery_headers: fn _, _, _ -> exit(:private) end)
    assert reload(failed).last_error == "delivery_headers_failed"
    refute_received {:http_received, _}
  end

  test "certificate mismatch is non-retryable from a per-endpoint resolver before body bytes are sent" do
    {server, port} =
      HttpReceiver.start(
        socket_type:
          {:ssl,
           [
             certfile: String.to_charlist(@tls <> "server-both-san.pem"),
             keyfile: String.to_charlist(@tls <> "server.key")
           ]}
      )

    on_exit(fn -> :inets.stop(:httpd, server) end)
    [{:Certificate, ca, _}] = :public_key.pem_decode(File.read!(@tls <> "local-ca.pem"))
    {row, _} = row!(port, 200, "https")

    assert :ok =
             run(row,
               certificate_pin: {__MODULE__, :pin},
               http_opts: [validate_destination: false, cacerts: [ca]]
             )

    assert %{status: :dead_letter, last_error: "certificate_pin_mismatch", attempts: 1} =
             reload(row)

    refute_received {:http_received, _}
  end
end
