defmodule AshHooks.TestEventTest do
  @moduledoc """
  Test events: a signed synthetic event of a chosen type to ONE endpoint,
  outside subscriptions — no subscription row is consulted or needed. The
  default payload marks itself as a test, every send emits a test-marked
  telemetry event beside the normal delivery lifecycle, and the send is a
  REAL HTTP delivery to a REAL loopback receiver.
  """

  defmodule Endpoint do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.TestEventTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Endpoint]

    sqlite do
      table("test_event_endpoints")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read, :create, :update])
      default_accept(:*)
    end
  end

  defmodule FlaggedDelivery do
    @moduledoc false
    # test_tracking :on — the delivery log can filter test sends
    use Ash.Resource,
      domain: AshHooks.TestEventTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundDelivery]

    sqlite do
      table("test_event_flagged")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      timestamps()
    end

    actions do
      defaults([:read])
    end

    outbound_delivery do
      test_tracking(:on)
    end
  end

  defmodule Attempt do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.TestEventTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundAttempt]

    sqlite do
      table("test_event_attempts")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Delivery do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.TestEventTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundDelivery]

    sqlite do
      table("test_event_deliveries")
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
      resource(AshHooks.TestEventTest.Endpoint)
      resource(AshHooks.TestEventTest.Delivery)
      resource(AshHooks.TestEventTest.FlaggedDelivery)
      resource(AshHooks.TestEventTest.Attempt)
    end
  end

  use ExUnit.Case, async: false

  alias AshHooks.Test.Repo

  @endpoints "test_event_endpoints"
  @deliveries "test_event_deliveries"
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

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS test_event_flagged (
      id TEXT PRIMARY KEY, event_uuid TEXT NOT NULL, event_type TEXT NOT NULL,
      payload BLOB NOT NULL, endpoint_id TEXT NOT NULL, subscription_id TEXT,
      signing_mode TEXT, status TEXT NOT NULL DEFAULT 'pending',
      attempts INTEGER NOT NULL DEFAULT 0, response_status INTEGER,
      response_snippet TEXT, last_error TEXT, next_attempt_at TEXT,
      dispatch_source TEXT NOT NULL DEFAULT 'v1:direct:unbound',
      dispatch_route TEXT NOT NULL DEFAULT 'v1:route:unbound',
      attempt_token TEXT, send_lease_expires_at TEXT,
      enqueue_token TEXT, enqueue_lease_expires_at TEXT,
      endpoint_snapshot TEXT, test INTEGER NOT NULL DEFAULT 0,
      inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS test_event_flagged_unique ON test_event_flagged (endpoint_id, event_uuid)"
    )

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS test_event_attempts (
      id TEXT PRIMARY KEY, delivery_pk TEXT NOT NULL, endpoint_id TEXT NOT NULL,
      event_uuid TEXT NOT NULL, event_type TEXT NOT NULL, attempt INTEGER NOT NULL,
      outcome TEXT NOT NULL, reason TEXT, response_status INTEGER,
      response_snippet TEXT, response_headers TEXT, latency_ms INTEGER,
      signing_key_ref TEXT, test INTEGER NOT NULL DEFAULT 0,
      attempted_at TEXT NOT NULL
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS test_event_attempts_unique ON test_event_attempts (delivery_pk, attempt)"
    )

    on_exit(fn ->
      Repo.query!("DROP TABLE IF EXISTS test_event_attempts")
      Repo.query!("DROP TABLE IF EXISTS test_event_flagged")
      Repo.query!("DROP TABLE IF EXISTS #{@deliveries}")
      Repo.query!("DROP TABLE IF EXISTS #{@endpoints}")
    end)

    :ok
  end

  setup do
    Repo.query!("DELETE FROM #{@deliveries}")
    Repo.query!("DELETE FROM test_event_flagged")
    Repo.query!("DELETE FROM test_event_attempts")
    Repo.query!("DELETE FROM #{@endpoints}")

    test_pid = self()

    :telemetry.attach_many(
      "test-event-test",
      [
        [:ash_hooks, :delivery, :test],
        [:ash_hooks, :delivery, :attempt]
      ],
      fn event, _m, metadata, _c -> send(test_pid, {event, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("test-event-test") end)
    :ok
  end

  # a real loopback receiver serving `count` 200 exchanges
  defp receiver_endpoint!(count \\ 2) do
    parent = self()
    {:ok, listen} = :gen_tcp.listen(0, [:binary, {:active, false}, {:ip, {127, 0, 0, 1}}])
    {:ok, port} = :inet.port(listen)

    spawn(fn ->
      serve(listen, count, parent)
      :gen_tcp.close(listen)
    end)

    id = Ash.UUID.generate()

    Repo.query!(
      "INSERT INTO #{@endpoints} (id, url, status, secret_ref) VALUES (?, ?, 'enabled', 'te-main')",
      [id, "http://127.0.0.1:#{port}/hook"]
    )

    Ash.get!(Endpoint, id, authorize?: false)
  end

  defp serve(_listen, 0, _parent), do: :ok

  defp serve(listen, n, parent) do
    case :gen_tcp.accept(listen, 10_000) do
      {:ok, socket} ->
        {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
        send(parent, {:request, request})

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 11\r\nconnection: close\r\n\r\n{\"ok\": true}"
          )

        :gen_tcp.close(socket)
        serve(listen, n - 1, parent)

      _closed_or_timeout ->
        :ok
    end
  end

  defp config(endpoint, overrides) do
    Keyword.merge(
      [
        deliveries: Delivery,
        secret_resolver: fn "te-main" -> {:ok, @secret} end,
        destination_policy: fn _url, _ctx -> :allow end,
        http_opts: [validate_destination: false]
      ],
      overrides
    )
  end

  test "a test send delivers a signed synthetic event outside subscriptions" do
    endpoint = receiver_endpoint!()

    assert {:ok, %{status: :succeeded, delivery: row}} =
             AshHooks.Delivery.test_send(endpoint,
               type: "invoice.paid",
               deliveries: Delivery,
               secret_resolver: fn "te-main" -> {:ok, @secret} end,
               destination_policy: fn _url, _ctx -> :allow end,
               http_opts: [validate_destination: false]
             )

    # one durable row, no subscription behind it, the chosen type, a fresh id
    assert row.event_type == "invoice.paid"
    assert row.subscription_id == nil
    assert row.response_status == 200
    assert String.starts_with?(row.event_uuid, "msg_")

    # the payload marks itself as a test
    decoded = Jason.decode!(row.payload)
    assert decoded["test"] == true
    assert decoded["type"] == "invoice.paid"
    assert decoded["timestamp"]

    # telemetry: the test marker beside the normal attempt lifecycle
    assert_receive {[:ash_hooks, :delivery, :test], %{endpoint_id: _, type: "invoice.paid"}}

    assert_receive {[:ash_hooks, :delivery, :attempt], %{event_uuid: id}}
    assert id == row.event_uuid

    # the receiver saw a REAL signed request with the synthetic bytes
    assert_receive {:request, request}
    assert request =~ "POST /hook HTTP/1.1"
    assert request =~ "webhook-signature: v1,"
    assert request =~ row.payload
  end

  test "a caller-supplied payload is used verbatim" do
    endpoint = receiver_endpoint!()
    payload = Jason.encode!(%{"test" => true, "probe" => 7})

    assert {:ok, %{delivery: row}} =
             AshHooks.Delivery.test_send(endpoint,
               type: "custom.event",
               payload: payload,
               deliveries: Delivery,
               secret_resolver: fn "te-main" -> {:ok, @secret} end,
               destination_policy: fn _url, _ctx -> :allow end,
               http_opts: [validate_destination: false]
             )

    assert row.payload == payload
    assert_receive {:request, request}
    assert request =~ payload
  end

  test "each test send is a NEW event (fresh ids, no dedup suppression)" do
    endpoint = receiver_endpoint!(2)

    for n <- 1..2 do
      assert {:ok, _} =
               AshHooks.Delivery.test_send(endpoint,
                 type: "repeat.me",
                 deliveries: Delivery,
                 secret_resolver: fn "te-main" -> {:ok, @secret} end,
                 destination_policy: fn _url, _ctx -> :allow end,
                 http_opts: [validate_destination: false]
               )
    end

    rows = Ash.read!(Delivery, authorize?: false)
    assert length(rows) == 2
    assert Enum.uniq_by(rows, & &1.event_uuid) |> length() == 2
  end

  test "a test send requires a live endpoint and a type" do
    endpoint = receiver_endpoint!(0)

    assert {:error, :type_required} =
             AshHooks.Delivery.test_send(endpoint,
               deliveries: Delivery,
               secret_resolver: fn "te-main" -> {:ok, @secret} end
             )

    Repo.query!("UPDATE #{@endpoints} SET status = 'disabled' WHERE id = ?", [endpoint.id])

    assert {:error, :endpoint_not_live} =
             AshHooks.Delivery.test_send(endpoint,
               type: "no.send",
               deliveries: Delivery,
               secret_resolver: fn "te-main" -> {:ok, @secret} end
             )
  end

  test "test_send argument and run error arms" do
    endpoint = receiver_endpoint!(0)

    # the no-opts call names the type error (the default-args arm)
    assert {:error, :type_required} = AshHooks.Delivery.test_send(endpoint)

    # an atom type canonicalizes; the still-disabled endpoint refuses
    Repo.query!("UPDATE #{@endpoints} SET status = 'disabled' WHERE id = ?", [endpoint.id])

    assert {:error, :endpoint_not_live} =
             AshHooks.Delivery.test_send(endpoint,
               type: :atom_type,
               deliveries: Delivery,
               secret_resolver: fn "te-main" -> {:ok, @secret} end
             )

    # a missing :deliveries resource is a named error
    Repo.query!("UPDATE #{@endpoints} SET status = 'enabled' WHERE id = ?", [endpoint.id])

    assert {:error, %AshHooks.Errors.Unknown.UnknownError{error: error}} =
             AshHooks.Delivery.test_send(endpoint,
               type: "no.deliveries",
               secret_resolver: fn "te-main" -> {:ok, @secret} end
             )

    assert error =~ ":deliveries"

    # a refused loopback port: the run's retryable outcome reports from the row
    {:ok, listen} = :gen_tcp.listen(0, [:binary, {:active, false}, {:ip, {127, 0, 0, 1}}])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)

    id = Ash.UUID.generate()

    Repo.query!(
      "INSERT INTO #{@endpoints} (id, url, status, secret_ref) VALUES (?, ?, 'enabled', 'te-main')",
      [id, "http://127.0.0.1:#{port}/hook"]
    )

    dead_endpoint = Ash.get!(Endpoint, id, authorize?: false)

    assert {:ok, %{status: :failed_retryable}} =
             AshHooks.Delivery.test_send(dead_endpoint,
               type: "refused.port",
               deliveries: Delivery,
               secret_resolver: fn "te-main" -> {:ok, @secret} end,
               destination_policy: fn _url, _ctx -> :allow end,
               http_opts: [validate_destination: false],
               max_attempts: 2
             )
  end

  test "a broken application clock surfaces the driver's error contract" do
    endpoint = receiver_endpoint!(0)

    assert {:error, {:driver_crash, _reason}} =
             AshHooks.Delivery.test_send(endpoint,
               type: "broken.clock",
               deliveries: Delivery,
               secret_resolver: fn "te-main" -> {:ok, @secret} end,
               now: fn -> raise "clock failed" end
             )
  end

  test "a failing test receiver reports the failed attempt, not a crash" do
    # an unreachable (unresolvable) endpoint: the single attempt fails as
    # transport and the row reports it
    endpoint =
      Ash.create!(
        Endpoint,
        %{
          url: "https://definitely-not-resolvable-ash-hooks-test.invalid/hook",
          secret_ref: "te-main"
        },
        authorize?: false
      )

    assert {:ok, %{status: :failed_retryable, delivery: row}} =
             AshHooks.Delivery.test_send(endpoint,
               type: "will.fail",
               deliveries: Delivery,
               max_attempts: 2,
               secret_resolver: fn "te-main" -> {:ok, @secret} end
             )

    assert row.last_error in ["nxdomain", "resolve_timeout"]
  end

  test "test sends are flagged in the delivery log AND the attempt history" do
    endpoint = receiver_endpoint!(2)

    # an ORDINARY dispatched row (the flag defaults false)
    real =
      Ash.create!(
        FlaggedDelivery,
        %{
          event_uuid: "evt_not_a_test",
          event_type: "real.event",
          payload: "{}",
          endpoint_id: endpoint.id
        },
        action: :dispatch,
        authorize?: false
      )

    # and a test send: flagged end to end
    assert {:ok, %{status: :succeeded, delivery: test_row}} =
             AshHooks.Delivery.test_send(endpoint,
               type: "flagged.event",
               deliveries: FlaggedDelivery,
               attempts: Attempt,
               secret_resolver: fn "te-main" -> {:ok, @secret} end,
               destination_policy: fn _url, _ctx -> :allow end,
               http_opts: [validate_destination: false]
             )

    assert real.test == false
    assert test_row.test == true

    # the delivery log filters on the flag
    {:ok, %{records: only_tests}} =
      AshHooks.Delivery.list(FlaggedDelivery, test: true)

    assert [%{id: id}] = only_tests
    assert id == test_row.id

    {:ok, %{records: no_tests}} = AshHooks.Delivery.list(FlaggedDelivery, test: false)
    assert [%{id: real_id}] = no_tests
    assert real_id == real.id

    # attempt history carries the flag and filters on it
    {:ok, %{records: test_attempts}} = AshHooks.OutboundAttempt.list(Attempt, test: true)
    assert [%{event_type: "flagged.event", test: true, event_uuid: id}] = test_attempts
    assert id == test_row.event_uuid

    # no non-test attempts exist (the ordinary row never sent)
    {:ok, %{records: []}} = AshHooks.OutboundAttempt.list(Attempt, test: false)
  end

  test "a per-delivery diagnostic capture rides a test send (snippet_capture)" do
    endpoint = receiver_endpoint!(1)

    assert {:ok, %{delivery: row}} =
             AshHooks.Delivery.test_send(endpoint,
               type: "captured.test",
               deliveries: FlaggedDelivery,
               secret_resolver: fn "te-main" -> {:ok, @secret} end,
               destination_policy: fn _url, _ctx -> :allow end,
               http_opts: [validate_destination: false],
               snippet_capture: true
             )

    # the delivery row keeps the marked, redacted capture (the per-delivery
    # diagnostic beside the per-endpoint setting)
    assert String.starts_with?(row.response_snippet, "[captured] ")
  end
end
