defmodule AshHooks.TransportTest do
  @moduledoc """
  The delivery transport behavior: an app routes ONE endpoint's deliveries
  to its own transport (a developer's local forwarder behind a CLI
  "listen" command) instead of HTTP — the SAME signing, attempts,
  attempt-history, classification, and telemetry apply, because the
  transport is the adapter-shaped seam the driver already drives.
  """

  defmodule Endpoint do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.TransportTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Endpoint]

    sqlite do
      table("transport_endpoints")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read, :create, :update])
      default_accept(:*)
    end
  end

  defmodule Delivery do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.TransportTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundDelivery]

    sqlite do
      table("transport_deliveries")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      timestamps()
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Attempt do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.TransportTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundAttempt]

    sqlite do
      table("transport_attempts")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(AshHooks.TransportTest.Endpoint)
      resource(AshHooks.TransportTest.Delivery)
      resource(AshHooks.TransportTest.Attempt)
    end
  end

  # the app's forwarder transport: captures the SIGNED request for the
  # test and answers 200 — the adapter-shaped contract
  defmodule ForwarderTransport do
    @moduledoc false
    @behaviour AshHooks.Transport

    def start_link, do: Agent.start_link(fn -> [] end, name: __MODULE__)
    def calls, do: Agent.get(__MODULE__, &Enum.reverse/1)
    def reset, do: Agent.update(__MODULE__, fn _ -> [] end)

    @impl true
    def request(method, url, headers, body, opts) do
      Agent.update(
        __MODULE__,
        &[%{method: method, url: url, headers: headers, body: body, opts: opts} | &1]
      )

      {:ok,
       %{
         status: 200,
         headers: [{"content-type", "application/json"}],
         body: ~s({"forwarded": true})
       }}
    end
  end

  defmodule FailingTransport do
    @moduledoc false
    @behaviour AshHooks.Transport

    @impl true
    def request(_m, _u, _h, _b, _o), do: {:error, :forwarder_unreachable}
  end

  defmodule CrashingTransport do
    @moduledoc false
    @behaviour AshHooks.Transport

    @impl true
    def request(_m, _u, _h, _b, _o), do: raise("transport crashed")
  end

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias AshHooks.Delivery, as: DeliveryRuntime
  alias AshHooks.Test.HttpReceiver
  alias AshHooks.Test.Repo

  @endpoints "transport_endpoints"
  @deliveries "transport_deliveries"
  @attempts "transport_attempts"
  @payload Jason.encode!(%{"order" => 1})
  @secret "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))
  @resolver_detail "private resolver detail: never persist or emit"

  setup_all do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@endpoints} (
      id TEXT PRIMARY KEY, url TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'enabled',
      secret_ref TEXT NOT NULL, previous_secret_ref TEXT, legacy_secret_ref TEXT,
      legacy_previous_secret_ref TEXT
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@deliveries} (
      id TEXT PRIMARY KEY, event_uuid TEXT NOT NULL, event_type TEXT NOT NULL,
      payload BLOB NOT NULL, endpoint_id TEXT NOT NULL, subscription_id TEXT,
      signing_mode TEXT, status TEXT NOT NULL DEFAULT 'pending',
      attempts INTEGER NOT NULL DEFAULT 0, response_status INTEGER,
      response_snippet TEXT, last_error TEXT, next_attempt_at TEXT,
      dispatch_source TEXT NOT NULL DEFAULT 'v1:direct:unbound',
      dispatch_route TEXT NOT NULL DEFAULT 'v1:route:unbound',
      attempt_token TEXT, send_lease_expires_at TEXT,
      enqueue_token TEXT, enqueue_lease_expires_at TEXT,
      endpoint_snapshot TEXT,
      inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@deliveries}_unique_delivery_index ON #{@deliveries} (endpoint_id, event_uuid)"
    )

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@attempts} (
      id TEXT PRIMARY KEY, delivery_pk TEXT NOT NULL, endpoint_id TEXT NOT NULL,
      event_uuid TEXT NOT NULL, event_type TEXT NOT NULL, attempt INTEGER NOT NULL,
      outcome TEXT NOT NULL, reason TEXT, response_status INTEGER,
      response_snippet TEXT, response_headers TEXT, latency_ms INTEGER,
      signing_key_ref TEXT, test INTEGER NOT NULL DEFAULT 0,
      attempted_at TEXT NOT NULL
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@attempts}_unique_attempt_index ON #{@attempts} (delivery_pk, attempt)"
    )

    on_exit(fn ->
      Repo.query!("DROP TABLE IF EXISTS #{@attempts}")
      Repo.query!("DROP TABLE IF EXISTS #{@deliveries}")
      Repo.query!("DROP TABLE IF EXISTS #{@endpoints}")
    end)

    :ok
  end

  setup do
    Repo.query!("DELETE FROM #{@attempts}")
    Repo.query!("DELETE FROM #{@deliveries}")
    Repo.query!("DELETE FROM #{@endpoints}")

    start_supervised!(%{
      id: ForwarderTransport,
      start: {ForwarderTransport, :start_link, []}
    })

    ForwarderTransport.reset()
    :ok
  end

  defp endpoint!(url \\ "https://hooks.example.test/hook") do
    Ash.create!(Endpoint, %{url: url, secret_ref: "tr-main"}, authorize?: false)
  end

  defp row!(endpoint, event_uuid) do
    Ash.create!(
      Delivery,
      %{
        event_uuid: event_uuid,
        event_type: "order_paid",
        payload: @payload,
        endpoint_id: endpoint.id
      },
      action: :dispatch,
      authorize?: false
    )
  end

  defp config(transport_resolver, overrides \\ []) do
    Keyword.merge(
      [
        deliveries: Delivery,
        endpoints: Endpoint,
        secret_resolver: fn "tr-main" -> {:ok, @secret} end,
        transport: transport_resolver
      ],
      overrides
    )
  end

  test "a routed endpoint delivers through the transport with full signing" do
    endpoint = endpoint!()
    row = row!(endpoint, "msg_transport_ok")

    assert :ok =
             DeliveryRuntime.run(
               %{"endpoint_id" => endpoint.id, "event_uuid" => row.event_uuid},
               config(fn _endpoint, _tenant -> ForwarderTransport end)
             )

    final = Ash.get!(Delivery, row.id, authorize?: false)
    assert final.status == :succeeded
    assert final.response_status == 200

    # the transport received the SAME signed request the wire would:
    # Standard Webhooks headers over the exact payload bytes
    [call] = ForwarderTransport.calls()
    assert call.method == :post
    assert call.url == endpoint.url
    assert call.body == @payload
    assert %{"webhook-signature" => sig, "webhook-id" => id} = call.headers
    assert String.starts_with?(sig, "v1,")
    assert id == row.event_uuid

    {:ok, %{id: ^id}} = AshHooks.Signing.verify(@payload, call.headers, @secret)
  end

  test "an unrouted endpoint keeps the HTTP adapter path" do
    endpoint = endpoint!()
    row = row!(endpoint, "msg_transport_none")

    assert {:snooze, _} =
             DeliveryRuntime.run(
               %{"endpoint_id" => endpoint.id, "event_uuid" => row.event_uuid},
               config(fn _endpoint, _tenant -> nil end)
             )

    # the resolver never routed it: no transport call, normal DNS transport
    assert ForwarderTransport.calls() == []

    assert Ash.get!(Delivery, row.id, authorize?: false).last_error in [
             "nxdomain",
             "resolve_timeout"
           ]
  end

  test "a transport error classifies as transport (retry), a crash is contained" do
    endpoint = endpoint!()

    # an app transport's own error atoms classify through the contents-free
    # floor ("unclassified" — arbitrary terms can carry secret material);
    # a raising transport is the adapter_crash class
    for {module, uuid, expected} <- [
          {FailingTransport, "msg_transport_fail", "unclassified"},
          {CrashingTransport, "msg_transport_crash", "adapter_crash"}
        ] do
      row = row!(endpoint, uuid)

      assert {:snooze, _} =
               DeliveryRuntime.run(
                 %{"endpoint_id" => endpoint.id, "event_uuid" => row.event_uuid},
                 config(fn _endpoint, _tenant -> module end, max_attempts: 2)
               )

      assert Ash.get!(Delivery, row.id, authorize?: false).last_error == expected
    end
  end

  test "a test send can target the transport (the CLI listen trigger)" do
    # the "trigger" a CLI listens for: a test send routed to the
    # forwarder, payload marked as a test, signature verifiable
    endpoint = endpoint!()

    assert {:ok, %{status: :succeeded, delivery: row}} =
             AshHooks.Delivery.test_send(endpoint,
               type: "cli.trigger",
               deliveries: Delivery,
               secret_resolver: fn "tr-main" -> {:ok, @secret} end,
               transport: {__MODULE__, :transport_for}
             )

    assert [call] = ForwarderTransport.calls()
    assert Jason.decode!(call.body)["test"] == true
    {:ok, %{id: id}} = AshHooks.Signing.verify(call.body, call.headers, @secret)
    assert id == row.event_uuid
  end

  test "a test send routes through the transport too" do
    endpoint = endpoint!()

    assert {:ok, %{status: :succeeded}} =
             DeliveryRuntime.test_send(endpoint,
               type: "cli.listen",
               deliveries: Delivery,
               secret_resolver: fn "tr-main" -> {:ok, @secret} end,
               transport: fn _endpoint, _tenant -> ForwarderTransport end
             )

    assert [%{body: body}] = ForwarderTransport.calls()
    assert Jason.decode!(body)["test"] == true
  end

  describe "transport resolver refusal" do
    setup do
      {server, port} = HttpReceiver.start()
      on_exit(fn -> :inets.stop(:httpd, server) end)

      # The registration cast refuses loopback. Seed the row directly, then
      # explicitly admit this real receiver at both send-time HTTP gates.
      id = Ash.UUID.generate()

      Repo.query!(
        "INSERT INTO #{@endpoints} (id, url, status, secret_ref) VALUES (?, ?, 'enabled', 'tr-main')",
        [id, "http://127.0.0.1:#{port}/200"]
      )

      handler = "transport-resolution-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach_many(
          handler,
          [
            [:ash_hooks, :delivery, :attempt],
            [:ash_hooks, :delivery, :result],
            [:ash_hooks, :delivery, :backoff],
            [:ash_hooks, :delivery, :dead_letter],
            [:ash_hooks, :delivery, :disable],
            [:ash_hooks, :attempt, :record_failed]
          ],
          &__MODULE__.capture_resolution_event/4,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler) end)
      %{endpoint: Ash.get!(Endpoint, id, authorize?: false)}
    end

    for shape <- [:function, :module_function] do
      @shape shape
      test "a nil #{@shape} resolver delivers to the real loopback listener", %{
        endpoint: endpoint
      } do
        resolver =
          if @shape == :function,
            do: fn _endpoint, _tenant -> nil end,
            else: {__MODULE__, :http_transport_for}

        row = row!(endpoint, "msg_nil_transport")

        assert :ok =
                 DeliveryRuntime.run(
                   %{"endpoint_id" => endpoint.id, "event_uuid" => row.event_uuid},
                   loopback_config(resolver)
                 )

        assert_receive {:http_received, request}, 1_000
        assert request.body == @payload

        assert {:ok, %{id: "msg_nil_transport"}} =
                 AshHooks.Signing.verify(request.body, request.headers, @secret)

        assert Ash.get!(Delivery, row.id, authorize?: false).status == :succeeded

        assert [%{outcome: :succeeded, response_status: 200}] =
                 Ash.read!(Attempt, authorize?: false)
      end
    end

    for failure <- [
          :raise,
          :throw,
          :exit,
          :invalid_atom,
          :invalid_module,
          :invalid_tuple,
          :invalid_binary,
          :module_function_raise
        ] do
      @failure failure
      test "#{@failure} refuses egress and records only transport_resolution", %{
        endpoint: endpoint
      } do
        assert_resolution_refused(endpoint, failing_resolver(@failure))
      end
    end
  end

  defp loopback_config(resolver) do
    config(resolver,
      attempts: Attempt,
      destination_policy: fn _url, _context -> :allow end,
      http_opts: [validate_destination: false],
      max_attempts: 2
    )
  end

  defp assert_resolution_refused(endpoint, resolver) do
    row = row!(endpoint, "msg_resolver_refusal")

    {result, logs} =
      with_log(fn ->
        DeliveryRuntime.run(
          %{"endpoint_id" => endpoint.id, "event_uuid" => row.event_uuid},
          loopback_config(resolver)
        )
      end)

    refute_receive {:http_received, _request}, 100
    assert {:snooze, delay} = result
    assert delay > 0

    final = Ash.get!(Delivery, row.id, authorize?: false)
    assert final.status == :failed_retryable
    assert final.last_error == "transport_resolution"
    assert final.attempts == 1
    assert %DateTime{} = final.next_attempt_at
    assert final.response_status == nil
    assert final.response_snippet == nil

    assert [attempt] = Ash.read!(Attempt, authorize?: false)
    assert attempt.outcome == :failed_retryable
    assert attempt.reason == "transport_resolution"
    assert attempt.attempt == 1
    assert attempt.response_status == nil
    assert attempt.response_snippet == nil
    assert attempt.response_headers == nil
    assert attempt.latency_ms == nil
    assert attempt.signing_key_ref == nil

    events = resolution_events()

    assert {[:ash_hooks, :delivery, :result], %{},
            %{
              endpoint_id: endpoint.id,
              event_uuid: row.event_uuid,
              status: :failed_retryable,
              response_status: nil,
              reason: "transport_resolution"
            }} in events

    refute Enum.any?(events, fn {name, _, _} -> name == [:ash_hooks, :delivery, :attempt] end)

    # Inspect raw persisted columns as well as emitted metadata, so resource
    # Inspect implementations cannot hide an accidentally stored resolver term.
    for surface <- [
          Repo.query!("SELECT * FROM #{@deliveries} WHERE id = ?", [row.id]).rows,
          Repo.query!("SELECT * FROM #{@attempts} WHERE id = ?", [attempt.id]).rows,
          logs,
          events
        ] do
      rendered = inspect(surface, limit: :infinity, printable_limit: :infinity)
      refute rendered =~ @resolver_detail
      refute rendered =~ "resolver_private_term"
      refute rendered =~ "RuntimeError"
    end
  end

  defp failing_resolver(:raise), do: &raising_transport_for/2

  defp failing_resolver(:throw),
    do: fn _, _ -> throw({:resolver_private_term, @resolver_detail}) end

  defp failing_resolver(:exit),
    do: fn _, _ -> exit({:resolver_private_term, @resolver_detail}) end

  defp failing_resolver(:invalid_atom), do: fn _, _ -> :resolver_private_term end
  defp failing_resolver(:invalid_module), do: fn _, _ -> String end

  defp failing_resolver(:invalid_tuple),
    do: fn _, _ -> {:resolver_private_term, @resolver_detail} end

  defp failing_resolver(:invalid_binary), do: fn _, _ -> @resolver_detail end
  defp failing_resolver(:module_function_raise), do: {__MODULE__, :raising_transport_for}

  def http_transport_for(_endpoint, _tenant), do: nil
  def raising_transport_for(_endpoint, _tenant), do: raise(@resolver_detail)

  def capture_resolution_event(event, measurements, metadata, owner),
    do: send(owner, {:resolution_event, event, measurements, metadata})

  defp resolution_events do
    receive do
      {:resolution_event, event, measurements, metadata} ->
        [{event, measurements, metadata} | resolution_events()]
    after
      0 -> []
    end
  end

  test "resolver failures are contained and a module-function resolver routes" do
    endpoint = endpoint!()
    row = row!(endpoint, "msg_transport_shapes")

    run_with = fn resolver ->
      fresh = row!(endpoint, "msg_shapes_#{System.unique_integer()}")

      result =
        DeliveryRuntime.run(
          %{"endpoint_id" => endpoint.id, "event_uuid" => fresh.event_uuid},
          config(resolver)
        )

      assert Ash.get!(Delivery, fresh.id, authorize?: false).last_error == "transport_resolution"
      result
    end

    # Exits, throws, and invalid returns refuse the attempt and retry.
    assert {:snooze, _} = run_with.(fn _e, _t -> exit(:boom) end)
    assert {:snooze, _} = run_with.(fn _e, _t -> throw(:boom) end)

    assert {:snooze, _} = run_with.(fn _e, _t -> "not-a-module" end)

    # an invalid :transport config shape falls back too
    assert {:snooze, _} =
             DeliveryRuntime.run(
               %{"endpoint_id" => endpoint.id, "event_uuid" => row.event_uuid},
               config(fn _e, _t -> nil end) |> Keyword.put(:transport, :garbage)
             )

    # and an {m, f} resolver routes
    routed = row!(endpoint, "msg_transport_mf")

    assert :ok =
             DeliveryRuntime.run(
               %{"endpoint_id" => endpoint.id, "event_uuid" => routed.event_uuid},
               config(fn _e, _t -> ForwarderTransport end)
               |> Keyword.put(:transport, {__MODULE__, :transport_for})
             )
  end

  def transport_for(_endpoint, _tenant), do: ForwarderTransport

  test "a crashing transport resolver retries under transport_resolution" do
    endpoint = endpoint!()
    row = row!(endpoint, "msg_transport_bad_resolver")

    assert {:snooze, _} =
             DeliveryRuntime.run(
               %{"endpoint_id" => endpoint.id, "event_uuid" => row.event_uuid},
               config(fn _endpoint, _tenant -> raise "resolver crashed" end)
             )

    assert Ash.get!(Delivery, row.id, authorize?: false).last_error == "transport_resolution"
  end
end
