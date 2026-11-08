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

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(AshHooks.TransportTest.Endpoint)
      resource(AshHooks.TransportTest.Delivery)
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

  alias AshHooks.Delivery, as: DeliveryRuntime
  alias AshHooks.Test.Repo

  @endpoints "transport_endpoints"
  @deliveries "transport_deliveries"
  @payload Jason.encode!(%{"order" => 1})
  @secret "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))

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

    on_exit(fn ->
      Repo.query!("DROP TABLE IF EXISTS #{@deliveries}")
      Repo.query!("DROP TABLE IF EXISTS #{@endpoints}")
    end)

    :ok
  end

  setup do
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

  test "every resolver shape resolves or falls back contained" do
    endpoint = endpoint!()
    row = row!(endpoint, "msg_transport_shapes")

    run_with = fn resolver ->
      fresh = row!(endpoint, "msg_shapes_#{System.unique_integer()}")

      DeliveryRuntime.run(
        %{"endpoint_id" => endpoint.id, "event_uuid" => fresh.event_uuid},
        config(fn _e, _t -> :ok end) |> Keyword.put(:transport, resolver)
      )
    end

    # an exiting and a throwing resolver fall back contained
    assert {:snooze, _} = run_with.(fn _e, _t -> exit(:boom) end)
    assert {:snooze, _} = run_with.(fn _e, _t -> throw(:boom) end)

    # a non-module resolution falls back
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

  test "a crashing transport resolver falls back to the HTTP adapter" do
    endpoint = endpoint!()
    row = row!(endpoint, "msg_transport_bad_resolver")

    assert {:snooze, _} =
             DeliveryRuntime.run(
               %{"endpoint_id" => endpoint.id, "event_uuid" => row.event_uuid},
               config(fn _endpoint, _tenant -> raise "resolver crashed" end)
             )

    assert Ash.get!(Delivery, row.id, authorize?: false).last_error in [
             "nxdomain",
             "resolve_timeout"
           ]
  end
end
