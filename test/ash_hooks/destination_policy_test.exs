defmodule AshHooks.DestinationPolicyTest do
  @moduledoc """
  The public send-time destination policy seam: a consumer module decides
  `:allow | :deny | :default` per URL ahead of the packaged SSRF check, so
  an app can carry its own allow and deny rules without forking the default
  gate. The allow arm drives a REAL loopback HTTP receiver over a scripted
  :gen_tcp listener (the bounded-http substrate pattern) — the send is a
  real request/response, not an adapter double.
  """

  defmodule Endpoint do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.DestinationPolicyTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Endpoint]

    sqlite do
      table("destination_policy_endpoints")
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
      domain: AshHooks.DestinationPolicyTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundDelivery]

    sqlite do
      table("destination_policy_deliveries")
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
      resource(AshHooks.DestinationPolicyTest.Endpoint)
      resource(AshHooks.DestinationPolicyTest.Delivery)
    end
  end

  # policies in the fixed decision vocabulary; DenyAll/DenyingTenant and
  # Crash are module callbacks ({m, f} seam), the context arm uses a fn
  defmodule AllowAll do
    @moduledoc false
    @behaviour AshHooks.DestinationPolicy

    @impl true
    def check(_url, _ctx), do: :allow
  end

  defmodule DenyAll do
    @moduledoc false
    @behaviour AshHooks.DestinationPolicy

    @impl true
    def check(_url, _ctx), do: :deny
  end

  defmodule CrashingPolicy do
    @moduledoc false
    @behaviour AshHooks.DestinationPolicy

    @impl true
    def check(_url, _ctx), do: raise("policy failed")
  end

  defmodule ContextCapturingPolicy do
    @moduledoc false
    @behaviour AshHooks.DestinationPolicy

    @impl true
    def check(url, ctx) do
      Agent.update(__MODULE__, fn _ -> {url, ctx} end)
      :deny
    end
  end

  use ExUnit.Case, async: false

  alias AshHooks.Delivery, as: DeliveryRuntime
  alias AshHooks.Test.Repo

  @endpoints "destination_policy_endpoints"
  @deliveries "destination_policy_deliveries"
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
      endpoint_snapshot TEXT
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
      id: ContextCapturingPolicy,
      start: {Agent, :start_link, [fn -> nil end, [name: ContextCapturingPolicy]]}
    })

    :ok
  end

  defp endpoint!(url \\ "https://hooks.example.test/accept") do
    Ash.create!(Endpoint, %{url: url, secret_ref: "policy-main"}, authorize?: false)
  end

  # a loopback endpoint cannot pass the registration cast (that is the
  # point of the allow rule) — seeded directly, the raw-SQL precedent
  defp loopback_endpoint!(url) do
    id = Ash.UUID.generate()

    Repo.query!(
      "INSERT INTO #{@endpoints} (id, url, status, secret_ref) VALUES (?, ?, 'enabled', 'policy-main')",
      [id, url]
    )

    Ash.get!(Endpoint, id, authorize?: false)
  end

  defp pending_row!(endpoint, event_uuid) do
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

  defp config(overrides) do
    Keyword.merge(
      [
        deliveries: Delivery,
        endpoints: Endpoint,
        secret_resolver: fn "policy-main" -> {:ok, @secret} end
      ],
      overrides
    )
  end

  # one scripted HTTP exchange: accept, read the request, reply 200
  defp loopback_receiver!(parent) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, {:active, false}, {:ip, {127, 0, 0, 1}}])
    {:ok, port} = :inet.port(listen)

    spawn(fn ->
      {:ok, socket} = :gen_tcp.accept(listen, 10_000)
      {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
      send(parent, {:policy_receiver_request, request})

      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 11\r\nconnection: close\r\n\r\n{\"ok\": true}"
      )

      :gen_tcp.close(socket)
      :gen_tcp.close(listen)
    end)

    port
  end

  test "a policy :deny dead-letters under destination_denied before any send" do
    endpoint = endpoint!()
    row = pending_row!(endpoint, "msg_policy_deny")

    assert :ok =
             DeliveryRuntime.run(
               %{"endpoint_id" => endpoint.id, "event_uuid" => row.event_uuid},
               config(destination_policy: {DenyAll, :check})
             )

    final = Ash.get!(Delivery, row.id, authorize?: false)
    assert final.status == :dead_letter
    assert final.last_error == "destination_denied"
    assert final.attempts == 1
  end

  test "a policy :allow bypasses the default gate and delivers to a real loopback receiver" do
    port = loopback_receiver!(self())
    endpoint = loopback_endpoint!("http://127.0.0.1:#{port}/hook")
    row = pending_row!(endpoint, "msg_policy_allow")

    assert :ok =
             DeliveryRuntime.run(
               %{"endpoint_id" => endpoint.id, "event_uuid" => row.event_uuid},
               config(
                 destination_policy: {AllowAll, :check},
                 # the adapter's own resolve-and-pin is the transport's
                 # boundary; an explicit allow pairs with its override
                 http_opts: [validate_destination: false]
               )
             )

    final = Ash.get!(Delivery, row.id, authorize?: false)
    assert final.status == :succeeded
    assert final.response_status == 200

    assert_receive {:policy_receiver_request, request}
    assert request =~ "POST /hook HTTP/1.1"
    assert request =~ "webhook-signature: v1,"
    assert request =~ @payload
  end

  test ":default runs the packaged tri-state (unresolvable retries under its honest label)" do
    endpoint = endpoint!("https://definitely-not-resolvable-ash-hooks-test.invalid/accept")
    row = pending_row!(endpoint, "msg_policy_default")

    assert {:snooze, delay} =
             DeliveryRuntime.run(
               %{"endpoint_id" => endpoint.id, "event_uuid" => row.event_uuid},
               config(
                 destination_policy: fn _url, _ctx -> :default end,
                 max_attempts: 2
               )
             )

    assert delay >= 1

    final = Ash.get!(Delivery, row.id, authorize?: false)
    assert final.status == :failed_retryable
    assert final.last_error in ["nxdomain", "resolve_timeout"]
  end

  test "a crashing policy is contained and retries under destination_policy_failed" do
    endpoint = endpoint!()
    row = pending_row!(endpoint, "msg_policy_crash")

    assert {:snooze, _delay} =
             DeliveryRuntime.run(
               %{"endpoint_id" => endpoint.id, "event_uuid" => row.event_uuid},
               config(destination_policy: {CrashingPolicy, :check})
             )

    final = Ash.get!(Delivery, row.id, authorize?: false)
    assert final.status == :failed_retryable
    assert final.last_error == "destination_policy_failed"
  end

  test "an invalid policy return is contained like a crash" do
    endpoint = endpoint!()
    row = pending_row!(endpoint, "msg_policy_invalid_return")

    assert {:snooze, _delay} =
             DeliveryRuntime.run(
               %{"endpoint_id" => endpoint.id, "event_uuid" => row.event_uuid},
               config(destination_policy: fn _url, _ctx -> :not_a_decision end)
             )

    final = Ash.get!(Delivery, row.id, authorize?: false)
    assert final.last_error == "destination_policy_failed"
  end

  test "the callback receives the URL and a context with the endpoint id and tenant" do
    endpoint = endpoint!()
    row = pending_row!(endpoint, "msg_policy_context")

    DeliveryRuntime.run(
      %{"endpoint_id" => endpoint.id, "event_uuid" => row.event_uuid, "tenant" => "org_a"},
      config(destination_policy: {ContextCapturingPolicy, :check})
    )

    assert {url, ctx} = Agent.get(ContextCapturingPolicy, & &1)
    assert url == endpoint.url
    assert ctx.endpoint_id == endpoint.id
    assert ctx.tenant == "org_a"
  end

  test "without a policy the boolean ssrf_check seam keeps its behavior" do
    endpoint = endpoint!()
    row = pending_row!(endpoint, "msg_policy_no_policy")

    assert :ok =
             DeliveryRuntime.run(
               %{"endpoint_id" => endpoint.id, "event_uuid" => row.event_uuid},
               config(ssrf_check: fn _url -> false end)
             )

    final = Ash.get!(Delivery, row.id, authorize?: false)
    assert final.status == :dead_letter
    assert final.last_error == "unsafe_destination"
  end
end
