defmodule AshHooks.NewSurfaceTenancyTest do
  @moduledoc """
  Tenancy through every NEW surface: attempt history, queries, resend and
  replay, test sends, health computation, key rolling, the event log, and
  event-log replay all take `:tenant`, stay isolated per tenant, and fail
  closed without one — exactly like the package's original operations.
  """

  defmodule Endpoint do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.NewSurfaceTenancyTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Endpoint]

    sqlite do
      table("tenancy_surface_endpoints")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      attribute(:org_id, :string, allow_nil?: false)
    end

    multitenancy do
      strategy(:attribute)
      attribute(:org_id)
    end

    actions do
      defaults([:read, :create, :update])
      default_accept(:*)
    end

    endpoint do
      key_lifecycle(:on)
      response_capture_attributes(:on)
    end
  end

  defmodule Subscription do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.NewSurfaceTenancyTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Subscription]

    sqlite do
      table("tenancy_surface_subscriptions")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      attribute(:org_id, :string, allow_nil?: false)
    end

    multitenancy do
      strategy(:attribute)
      attribute(:org_id)
    end

    actions do
      defaults([:read, :create])
      default_accept(:*)
    end

    subscription do
      endpoint_resource(AshHooks.NewSurfaceTenancyTest.Endpoint)
    end
  end

  defmodule Delivery do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.NewSurfaceTenancyTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundDelivery]

    sqlite do
      table("tenancy_surface_deliveries")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      attribute(:org_id, :string, allow_nil?: false)
      timestamps()
    end

    multitenancy do
      strategy(:attribute)
      attribute(:org_id)
    end

    actions do
      defaults([:read])
    end

    outbound_delivery do
      resend_tracking(:on)
    end
  end

  defmodule Attempt do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.NewSurfaceTenancyTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundAttempt]

    sqlite do
      table("tenancy_surface_attempts")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      attribute(:org_id, :string, allow_nil?: false)
    end

    multitenancy do
      strategy(:attribute)
      attribute(:org_id)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule EventLog do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.NewSurfaceTenancyTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundEvent]

    sqlite do
      table("tenancy_surface_events")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      attribute(:org_id, :string, allow_nil?: false)
      timestamps()
    end

    multitenancy do
      strategy(:attribute)
      attribute(:org_id)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Emitter do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.NewSurfaceTenancyTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks]

    sqlite do
      table("tenancy_surface_emitters")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read, :create])
    end

    webhooks do
      outbound :order_paid do
        subscriptions(AshHooks.NewSurfaceTenancyTest.Subscription)
        deliveries(AshHooks.NewSurfaceTenancyTest.Delivery)
        events(AshHooks.NewSurfaceTenancyTest.EventLog)
      end
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(AshHooks.NewSurfaceTenancyTest.Endpoint)
      resource(AshHooks.NewSurfaceTenancyTest.Subscription)
      resource(AshHooks.NewSurfaceTenancyTest.Delivery)
      resource(AshHooks.NewSurfaceTenancyTest.Attempt)
      resource(AshHooks.NewSurfaceTenancyTest.EventLog)
      resource(AshHooks.NewSurfaceTenancyTest.Emitter)
    end
  end

  use ExUnit.Case, async: false

  alias AshHooks.Delivery, as: DeliveryRuntime
  alias AshHooks.Test.Repo

  @endpoints "tenancy_surface_endpoints"
  @subscriptions "tenancy_surface_subscriptions"
  @deliveries "tenancy_surface_deliveries"
  @attempts "tenancy_surface_attempts"
  @events "tenancy_surface_events"
  @emitters "tenancy_surface_emitters"
  @payload Jason.encode!(%{"order" => 1})
  @secret "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))

  setup_all do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@endpoints} (
      id TEXT PRIMARY KEY, url TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'enabled',
      secret_ref TEXT NOT NULL, previous_secret_ref TEXT, legacy_secret_ref TEXT,
      legacy_previous_secret_ref TEXT,
      secret_created_at TEXT, secret_first_used_at TEXT, secret_retired_at TEXT,
      previous_secret_created_at TEXT, previous_secret_first_used_at TEXT,
      previous_secret_retired_at TEXT,
      response_capture INTEGER NOT NULL DEFAULT 0,
      response_capture_max_bytes INTEGER NOT NULL DEFAULT 2048,
      response_capture_retention_seconds INTEGER NOT NULL DEFAULT 2592000,
      response_header_allowlist TEXT,
      org_id TEXT NOT NULL
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@subscriptions} (
      id TEXT PRIMARY KEY, event_types TEXT NOT NULL, endpoint_id TEXT NOT NULL,
      signing_mode TEXT, org_id TEXT NOT NULL
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
      resend_baseline INTEGER NOT NULL DEFAULT 0,
      resend_count INTEGER NOT NULL DEFAULT 0,
      last_resend_by TEXT, last_resend_at TEXT,
      inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      org_id TEXT NOT NULL
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@deliveries}_unique_delivery_index ON #{@deliveries} (org_id, endpoint_id, event_uuid)"
    )

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@attempts} (
      id TEXT PRIMARY KEY, delivery_pk TEXT NOT NULL, endpoint_id TEXT NOT NULL,
      event_uuid TEXT NOT NULL, event_type TEXT NOT NULL, attempt INTEGER NOT NULL,
      outcome TEXT NOT NULL, reason TEXT, response_status INTEGER,
      response_snippet TEXT, response_headers TEXT, latency_ms INTEGER,
      signing_key_ref TEXT, test INTEGER NOT NULL DEFAULT 0,
      attempted_at TEXT NOT NULL,
      org_id TEXT NOT NULL
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@attempts}_unique_attempt_index ON #{@attempts} (org_id, delivery_pk, attempt)"
    )

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@events} (
      id TEXT PRIMARY KEY, event_uuid TEXT NOT NULL, event_type TEXT NOT NULL,
      version INTEGER, payload BLOB NOT NULL,
      inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      org_id TEXT NOT NULL
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@events}_unique_event_index ON #{@events} (org_id, event_uuid)"
    )

    Repo.query!("CREATE TABLE IF NOT EXISTS #{@emitters} (id TEXT PRIMARY KEY)")

    on_exit(fn ->
      Repo.query!("DROP TABLE IF EXISTS #{@events}")
      Repo.query!("DROP TABLE IF EXISTS #{@attempts}")
      Repo.query!("DROP TABLE IF EXISTS #{@deliveries}")
      Repo.query!("DROP TABLE IF EXISTS #{@subscriptions}")
      Repo.query!("DROP TABLE IF EXISTS #{@endpoints}")
      Repo.query!("DROP TABLE IF EXISTS #{@emitters}")
    end)

    :ok
  end

  setup do
    for table <- [@events, @attempts, @deliveries, @subscriptions, @endpoints, @emitters] do
      Repo.query!("DELETE FROM #{table}")
    end

    :ok
  end

  defp tenant_endpoint!(org, status \\ :enabled) do
    Ash.create!(
      Endpoint,
      %{url: "https://hooks.example.test/hook", secret_ref: "ts-#{org}", status: status},
      tenant: org,
      authorize?: false
    )
  end

  defp config(org) do
    ref = "ts-" <> org

    [
      deliveries: Delivery,
      endpoints: Endpoint,
      attempts: Attempt,
      secret_resolver: fn ^ref -> {:ok, @secret} end,
      tenant: org
    ]
  end

  test "every new surface threads the tenant or fails closed" do
    org_a = "org_a"
    org_b = "org_b"

    a_endpoint = tenant_endpoint!(org_a)
    b_endpoint = tenant_endpoint!(org_b)

    for {org, endpoint} <- [{org_a, a_endpoint}, {org_b, b_endpoint}] do
      Ash.create!(Subscription, %{endpoint_id: endpoint.id, event_types: ["order_paid"]},
        tenant: org,
        authorize?: false
      )
    end

    # dispatch per tenant: the event log + delivery rows are tenant-scoped
    {:ok, event} = AshHooks.Event.new(type: "order_paid", payload: @payload, id: "msg_ts_a")
    {:ok, _} = AshHooks.dispatch(Emitter, :order_paid, event, tenant: org_a)

    {:ok, b_event} = AshHooks.Event.new(type: "order_paid", payload: @payload, id: "msg_ts_b")
    {:ok, _} = AshHooks.dispatch(Emitter, :order_paid, b_event, tenant: org_b)

    # tenant-less dispatch against the multitenant set fails closed
    assert {:error, :tenant_required} = AshHooks.dispatch(Emitter, :order_paid, event)

    # queries see only their tenant
    {:ok, %{records: a_rows}} = AshHooks.Delivery.list(Delivery, tenant: org_a)
    assert [%{event_uuid: "msg_ts_a"}] = a_rows

    {:ok, %{records: b_rows}} = AshHooks.Delivery.list(Delivery, tenant: org_b)
    assert [%{event_uuid: "msg_ts_b"}] = b_rows

    assert {:error, :tenant_required} = AshHooks.Delivery.list(Delivery)

    {:ok, %{records: a_events}} = AshHooks.OutboundEvent.list(EventLog, tenant: org_a)
    assert [%{event_uuid: "msg_ts_a"}] = a_events

    # attempt history: a tenant-scoped send records tenant-scoped rows
    row = hd(a_rows)

    assert :ok =
             DeliveryRuntime.run(
               %{
                 "endpoint_id" => a_endpoint.id,
                 "event_uuid" => row.event_uuid,
                 "tenant" => org_a
               },
               Keyword.put(config(org_a), :destination_policy, fn _u, _c -> :deny end)
             )

    test_pid = self()

    :telemetry.attach_many(
      "ts-probe",
      [[:ash_hooks, :attempt, :record_failed]],
      fn e, _m, md, _c -> send(test_pid, {e, md}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("ts-probe") end)

    assert {:ok, %{records: a_attempts}} = AshHooks.OutboundAttempt.list(Attempt, tenant: org_a)
    assert [%{event_uuid: "msg_ts_a"}] = a_attempts

    assert {:error, :tenant_required} = AshHooks.OutboundAttempt.list(Attempt)

    assert {:error, :tenant_required} =
             AshHooks.EndpointHealth.stats(Attempt, endpoint_id: a_endpoint.id)

    assert {:error, :tenant_required} = AshHooks.EndpointHealth.sweep(Endpoint, Attempt)

    assert {:ok, %{attempts: 1}} =
             AshHooks.EndpointHealth.stats(Attempt, endpoint_id: a_endpoint.id, tenant: org_a)

    # test sends: tenant-scoped rows, fail closed without
    assert {:ok, %{delivery: test_row}} =
             DeliveryRuntime.test_send(a_endpoint,
               type: "tenant.probe",
               deliveries: Delivery,
               secret_resolver: fn "ts-org_a" -> {:ok, @secret} end,
               destination_policy: fn _u, _c -> :deny end,
               tenant: org_a
             )

    assert test_row.org_id == org_a

    assert {:error, :tenant_required} =
             DeliveryRuntime.test_send(a_endpoint,
               type: "tenant.probe",
               deliveries: Delivery,
               secret_resolver: fn _ref -> {:ok, @secret} end
             )

    # resend: tenant-gated, and cross-tenant refusals stay named
    Repo.query!("UPDATE #{@deliveries} SET status = 'dead_letter', attempts = 1 WHERE id = ?", [
      test_row.id
    ])

    dead = Ash.get!(Delivery, test_row.id, tenant: org_a, authorize?: false)

    assert {:ok, %{status: :resent}} =
             DeliveryRuntime.resend(dead,
               requested_by: "ops-tenant",
               endpoints: Endpoint,
               tenant: org_a
             )

    assert {:error, :tenant_required} =
             DeliveryRuntime.resend(dead, requested_by: "ops-tenant", endpoints: Endpoint)

    # bulk replay: tenant-scoped counts
    assert {:ok, %{count: 1}} =
             DeliveryRuntime.replay(Delivery,
               endpoints: Endpoint,
               requested_by: "ops",
               status: [:dead_letter],
               dry_run: true,
               tenant: org_a
             )

    assert {:error, :tenant_required} =
             DeliveryRuntime.replay(Delivery,
               endpoints: Endpoint,
               requested_by: "ops",
               status: [:dead_letter]
             )

    # key rolling: tenant-gated writes
    assert {:ok, rolled} =
             AshHooks.Endpoint.roll_secret(a_endpoint,
               new_secret_ref: "ts-#{org_a}-v2",
               tenant: org_a
             )

    assert rolled.org_id == org_a

    assert {:error, :tenant_required} =
             AshHooks.Endpoint.roll_secret(a_endpoint, new_secret_ref: "ts-#{org_a}-v3")

    assert {:ok, retired} = AshHooks.Endpoint.expire_previous_secret(rolled, tenant: org_a)
    assert retired.previous_secret_ref == nil

    assert {:error, :tenant_required} = AshHooks.Endpoint.expire_previous_secret(rolled)

    assert {:ok, 0} = AshHooks.Endpoint.expire_previous_secrets(Endpoint, tenant: org_a)

    assert {:error, :tenant_required} =
             AshHooks.Endpoint.expire_previous_secrets(Endpoint)

    # event-log replay: tenant-scoped, cross-tenant endpoints named
    later_b = tenant_endpoint!(org_b)

    assert {:ok, %{created: 1}} =
             AshHooks.OutboundEvent.replay(EventLog, later_b,
               event_uuid: "msg_ts_b",
               deliveries: Delivery,
               declaration: {Emitter, :order_paid},
               endpoints: Endpoint,
               requested_by: "ops",
               tenant: org_b
             )

    assert {:error, :tenant_required} =
             AshHooks.OutboundEvent.replay(EventLog, later_b,
               event_uuid: "msg_ts_b",
               deliveries: Delivery,
               declaration: {Emitter, :order_paid},
               endpoints: Endpoint,
               requested_by: "ops"
             )

    # and event-log retention is tenant-scoped
    assert {:ok, 0} =
             AshHooks.OutboundEvent.prune(EventLog,
               older_than: DateTime.add(DateTime.utc_now(), -86_400, :second),
               tenant: org_a
             )

    assert {:error, :tenant_required} =
             AshHooks.OutboundEvent.prune(EventLog, older_than: DateTime.utc_now())
  end

  @tag release_fix: 1
  test "release replay rearms a terminal delivery in its tenant" do
    endpoint = tenant_endpoint!("tenant-a")

    Ash.create!(Subscription, %{endpoint_id: endpoint.id, event_types: ["order_paid"]},
      tenant: "tenant-a",
      authorize?: false
    )

    {:ok, event} =
      AshHooks.Event.new(type: :order_paid, payload: @payload, id: "release-replay-tenant")

    {:ok, [_]} = AshHooks.dispatch(Emitter, :order_paid, event, tenant: "tenant-a")
    Repo.query!("UPDATE #{@deliveries} SET status = 'dead_letter' WHERE org_id = ?", ["tenant-a"])

    assert {:ok, %{re_sent: 1, skipped: 0}} =
             AshHooks.OutboundEvent.replay(EventLog, endpoint,
               event_uuid: event.id,
               deliveries: Delivery,
               declaration: {Emitter, :order_paid},
               endpoints: Endpoint,
               requested_by: "operator",
               tenant: "tenant-a"
             )

    assert [%{status: :pending, last_resend_by: "operator"}] =
             Ash.read!(Delivery, tenant: "tenant-a", authorize?: false)
  end
end
