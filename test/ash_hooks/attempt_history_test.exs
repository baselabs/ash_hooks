defmodule AshHooks.AttemptHistoryTest do
  @moduledoc """
  The attempt-history extension: every delivery attempt records a durable
  row (time, outcome, classified reason, HTTP status, latency, the signing
  key REFERENCE) beside the delivery ledger, written through the runtime's
  own fenced result paths. Response bodies stay off unless an endpoint opts
  in per row; an opted-in endpoint bounds the captured bytes and keeps only
  allowlisted response headers. The list queries filter by endpoint,
  status/outcome, event type, and time range with keyset pagination.
  """

  defmodule Repo do
    @moduledoc false
    use AshSqlite.Repo, otp_app: :ash_hooks
    @impl true
    def write_transactions?, do: true
    @impl true
    def min_sqlite_version, do: %Version{major: 3, minor: 54, patch: 1}
  end

  defmodule Endpoint do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.AttemptHistoryTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Endpoint]

    sqlite do
      table("attempt_history_endpoints")
      repo(AshHooks.AttemptHistoryTest.Repo)
    end

    actions do
      defaults([:read, :create, :update])
      default_accept(:*)
    end

    endpoint do
      response_capture_attributes(:on)
    end
  end

  defmodule PlainEndpoint do
    @moduledoc false
    # no response_capture_attributes declaration: the capture columns are
    # NOT injected (the opt-out shape existing installs keep)
    use Ash.Resource,
      domain: AshHooks.AttemptHistoryTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Endpoint]

    sqlite do
      table("attempt_history_endpoints")
      repo(AshHooks.AttemptHistoryTest.Repo)
    end

    actions do
      defaults([:read, :create, :update])
      default_accept(:*)
    end
  end

  defmodule Delivery do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.AttemptHistoryTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundDelivery]

    sqlite do
      table("attempt_history_deliveries")
      repo(AshHooks.AttemptHistoryTest.Repo)
    end

    attributes do
      timestamps()
    end

    actions do
      defaults([:read])
    end
  end

  defmodule NoTimestampsDelivery do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.AttemptHistoryTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundDelivery]

    sqlite do
      table("attempt_history_no_ts")
      repo(AshHooks.AttemptHistoryTest.Repo)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Attempt do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.AttemptHistoryTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundAttempt]

    sqlite do
      table("attempt_history_attempts")
      repo(AshHooks.AttemptHistoryTest.Repo)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(AshHooks.AttemptHistoryTest.Endpoint)
      resource(AshHooks.AttemptHistoryTest.PlainEndpoint)
      resource(AshHooks.AttemptHistoryTest.Delivery)
      resource(AshHooks.AttemptHistoryTest.NoTimestampsDelivery)
      resource(AshHooks.AttemptHistoryTest.Attempt)
    end
  end

  use ExUnit.Case, async: false

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshHooks.Delivery, as: DeliveryRuntime

  @endpoints "attempt_history_endpoints"
  @deliveries "attempt_history_deliveries"
  @attempts "attempt_history_attempts"
  @payload Jason.encode!(%{"order" => 1})
  @secret "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))

  setup_all do
    Application.put_env(:ash_hooks, Repo, database: ":memory:", pool_size: 1)
    start_supervised!(Repo)
    on_exit(fn -> Application.delete_env(:ash_hooks, Repo) end)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@endpoints} (
      id TEXT PRIMARY KEY, url TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'enabled',
      secret_ref TEXT NOT NULL, previous_secret_ref TEXT, legacy_secret_ref TEXT,
      legacy_previous_secret_ref TEXT,
      response_capture INTEGER NOT NULL DEFAULT 0,
      response_capture_max_bytes INTEGER NOT NULL DEFAULT 2048,
      response_capture_retention_seconds INTEGER NOT NULL DEFAULT 2592000,
      response_header_allowlist TEXT
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
      # The supervised in-memory repo owns these tables and removes them on shutdown.
      :ok
    end)

    :ok
  end

  setup do
    Repo.query!("DELETE FROM #{@attempts}")
    Repo.query!("DELETE FROM #{@deliveries}")
    Repo.query!("DELETE FROM #{@endpoints}")

    test_pid = self()

    :telemetry.attach_many(
      "attempt-history-test",
      [[:ash_hooks, :attempt, :record_failed]],
      fn event, _measurements, metadata, _config ->
        send(test_pid, {event, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("attempt-history-test") end)
    :ok
  end

  defp endpoint!(opts \\ []) do
    Ash.create!(
      Endpoint,
      Keyword.merge([url: "https://hooks.example.test/accept", secret_ref: "hist-main"], opts),
      authorize?: false
    )
  end

  # a REAL loopback HTTP receiver serving `count` 200 exchanges; the
  # endpoint row is seeded directly (loopback literals cannot pass the
  # registration cast — the destination-policy allow arm's whole point)
  defp receiver_endpoint!(count \\ 4, opts \\ []) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, {:active, false}, {:ip, {127, 0, 0, 1}}])
    {:ok, port} = :inet.port(listen)
    status = Keyword.get(opts, :status, 200)
    body = Keyword.get(opts, :body, "{\"ok\": true}")

    spawn(fn ->
      serve_exchanges(listen, count, status, body)
      :gen_tcp.close(listen)
    end)

    id = Ash.UUID.generate()
    opts = Keyword.merge([response_capture: false], opts)

    Repo.query!(
      """
      INSERT INTO #{@endpoints}
        (id, url, status, secret_ref, response_capture, response_capture_max_bytes,
         response_capture_retention_seconds, response_header_allowlist)
      VALUES (?, ?, 'enabled', 'hist-main', ?, ?, ?, ?)
      """,
      [
        id,
        "http://127.0.0.1:#{port}/hook",
        if(opts[:response_capture], do: 1, else: 0),
        opts[:response_capture_max_bytes] || 2048,
        opts[:response_capture_retention_seconds] || 2_592_000,
        Jason.encode!(opts[:response_header_allowlist] || [])
      ]
    )

    Ash.get!(Endpoint, id, authorize?: false)
  end

  defp serve_exchanges(_listen, 0, _status, _body), do: :ok

  defp serve_exchanges(listen, n, status, body) do
    case :gen_tcp.accept(listen, 10_000) do
      {:ok, socket} ->
        _ = :gen_tcp.recv(socket, 0, 5_000)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 #{status} #{reason_phrase(status)}\r\ncontent-type: application/json\r\n" <>
              "x-request-id: req-1\r\nx-secret-header: hush\r\n" <>
              "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
          )

        :gen_tcp.close(socket)
        serve_exchanges(listen, n - 1, status, body)

      _listener_closed_or_timeout ->
        :ok
    end
  end

  defp reason_phrase(200), do: "OK"
  defp reason_phrase(410), do: "Gone"
  defp reason_phrase(500), do: "Internal Server Error"
  defp reason_phrase(_other), do: "Status"

  defp pending_row!(endpoint, event_uuid, opts \\ []) do
    Ash.create!(
      Delivery,
      %{
        event_uuid: event_uuid,
        event_type: opts[:event_type] || "order_paid",
        payload: opts[:payload] || @payload,
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
        attempts: Attempt,
        secret_resolver: fn "hist-main" -> {:ok, @secret} end
      ],
      overrides
    )
  end

  # the success arms drive REAL loopback HTTP through the destination
  # policy allow + the adapter's loopback test seam (validate_destination:
  # false is the documented loopback listener seam, :test-only at compile)
  defp run!(endpoint, row) do
    DeliveryRuntime.run(
      %{"endpoint_id" => endpoint.id, "event_uuid" => row.event_uuid},
      config(
        destination_policy: fn _url, _ctx -> :allow end,
        http_opts: [validate_destination: false]
      )
    )
  end

  defp attempts_for(row) do
    Ash.read!(Attempt, authorize?: false)
    |> Enum.filter(&(&1.delivery_pk == %{"id" => row.id}))
    |> Enum.sort_by(& &1.attempt)
  end

  test "a successful send records one attempt row with status, latency, and the signing key ref" do
    endpoint = receiver_endpoint!()
    row = pending_row!(endpoint, "msg_hist_success")

    assert :ok = run!(endpoint, row)

    [attempt] = attempts_for(row)
    assert attempt.attempt == 1
    assert attempt.outcome == :succeeded
    assert attempt.reason == nil
    assert attempt.response_status == 200
    assert is_integer(attempt.latency_ms) and attempt.latency_ms >= 0
    assert attempt.signing_key_ref == "hist-main"
    assert attempt.event_uuid == row.event_uuid
    assert attempt.event_type == "order_paid"
    assert attempt.endpoint_id == endpoint.id
    assert %DateTime{} = attempt.attempted_at
    # no body bytes by default: the fixed summary grammar
    assert attempt.response_snippet == "200 json token=application/json"
    assert attempt.response_headers == nil
  end

  test "a retryable failure records its classified reason" do
    endpoint = endpoint!()
    row = pending_row!(endpoint, "msg_hist_retry")

    assert {:snooze, _} =
             DeliveryRuntime.run(
               %{"endpoint_id" => endpoint.id, "event_uuid" => row.event_uuid},
               config(
                 ssrf_check: fn _url -> true end,
                 secret_resolver: fn _ -> {:error, :boom} end
               )
             )

    [attempt] = attempts_for(row)
    assert attempt.outcome == :failed_retryable
    assert attempt.reason == "secret_resolution"
    # a PRE-SEND failure made no request: no latency, no key used
    assert attempt.latency_ms == nil
    assert attempt.signing_key_ref == nil
  end

  test "a FAILED REQUEST records its latency and the key that signed it" do
    # a real request attempt against a dead loopback port: the connection
    # is refused mid-flight — the attempt row must carry how long the
    # request ran and which signing key signed it
    {:ok, listen} = :gen_tcp.listen(0, [:binary, {:active, false}, {:ip, {127, 0, 0, 1}}])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)

    id = Ash.UUID.generate()

    Repo.query!(
      "INSERT INTO #{@endpoints} (id, url, status, secret_ref) VALUES (?, ?, 'enabled', 'hist-main')",
      [id, "http://127.0.0.1:#{port}/hook"]
    )

    endpoint = Ash.get!(Endpoint, id, authorize?: false)
    row = pending_row!(endpoint, "msg_hist_failed_request")

    assert {:snooze, _} = run!(endpoint, row)

    [attempt] = attempts_for(row)
    assert attempt.outcome == :failed_retryable
    assert attempt.reason == "econnrefused"
    # the request WAS made: its duration and signing key are recorded
    assert is_integer(attempt.latency_ms) and attempt.latency_ms >= 0
    assert attempt.signing_key_ref == "hist-main"
    assert attempt.response_status == nil
    assert attempt.response_snippet == nil
  end

  test "a dead-letter records its reason and response" do
    endpoint = endpoint!()
    row = pending_row!(endpoint, "msg_hist_dead")

    assert :ok =
             DeliveryRuntime.run(
               %{"endpoint_id" => endpoint.id, "event_uuid" => row.event_uuid},
               config(ssrf_check: fn _url -> false end)
             )

    [attempt] = attempts_for(row)
    assert attempt.outcome == :dead_letter
    assert attempt.reason == "unsafe_destination"
  end

  test "attempt rows are idempotent per (delivery, attempt number)" do
    endpoint = receiver_endpoint!()
    row = pending_row!(endpoint, "msg_hist_idempotent")

    assert :ok = run!(endpoint, row)
    # a re-drive of the now-terminal row does not append history
    assert :ok = run!(endpoint, row)

    assert length(attempts_for(row)) == 1
  end

  describe "per-endpoint response capture" do
    test "an opted-in endpoint captures the redacted body and only allowlisted headers" do
      endpoint =
        receiver_endpoint!(4,
          response_capture: true,
          response_header_allowlist: ["content-type", "x-request-id"]
        )

      row = pending_row!(endpoint, "msg_hist_capture")

      assert :ok = run!(endpoint, row)

      [attempt] = attempts_for(row)

      assert String.starts_with?(attempt.response_snippet, "[captured] ")
      assert attempt.response_snippet =~ "{\"ok\": true}"
      # only the allowlisted names survive (x-secret-header does not)
      assert attempt.response_headers == %{
               "content-type" => "application/json",
               "x-request-id" => "req-1"
             }
    end

    test "capture stays off when the endpoint row did not opt in" do
      endpoint = receiver_endpoint!()
      row = pending_row!(endpoint, "msg_hist_capture_off")

      assert :ok = run!(endpoint, row)

      [attempt] = attempts_for(row)
      assert attempt.response_snippet == "200 json token=application/json"
      assert attempt.response_headers == nil
    end
  end

  test "the capture columns are absent without response_capture_attributes :on" do
    refute ResourceInfo.attribute(PlainEndpoint, :response_capture)
    assert ResourceInfo.attribute(Endpoint, :response_capture)
  end

  test "a failed history write never fails the send (telemetry carries it)" do
    endpoint = receiver_endpoint!()
    row = pending_row!(endpoint, "msg_hist_write_fail")

    Repo.query!("DROP TABLE IF EXISTS #{@attempts}")

    assert :ok = run!(endpoint, row)

    assert_receive {[:ash_hooks, :attempt, :record_failed], %{event_uuid: "msg_hist_write_fail"}},
                   1_000

    # the attempts table returns for the remaining tests
    recreate_attempts!()
  end

  describe "list queries with keyset pagination" do
    test "deliveries filter by endpoint, status, event type, and time range" do
      endpoint = receiver_endpoint!()
      other = endpoint!()

      a = pending_row!(endpoint, "msg_q_a", event_type: "order_paid")
      b = pending_row!(endpoint, "msg_q_b", event_type: "order_canceled")
      _c = pending_row!(other, "msg_q_c", event_type: "order_paid")

      assert :ok = run!(endpoint, a)
      # b stays pending

      {:ok, %{records: rows}} =
        AshHooks.Delivery.list(Delivery, endpoint_id: endpoint.id)

      assert length(rows) == 2

      {:ok, %{records: rows}} =
        AshHooks.Delivery.list(Delivery, endpoint_id: endpoint.id, status: [:pending])

      assert [%{id: b_id}] = rows
      assert b_id == b.id

      {:ok, %{records: rows}} =
        AshHooks.Delivery.list(Delivery, event_type: "order_canceled")

      assert [%{id: ^b_id}] = rows

      {:ok, %{records: rows}} =
        AshHooks.Delivery.list(Delivery,
          from: DateTime.add(DateTime.utc_now(), 60, :second)
        )

      assert rows == []

      {:ok, %{records: rows}} =
        AshHooks.Delivery.list(Delivery,
          to: DateTime.add(DateTime.utc_now(), -60, :second)
        )

      assert rows == []
    end

    test "keyset pagination walks deliveries newest-first" do
      endpoint = endpoint!()

      rows =
        for i <- 1..5 do
          row = pending_row!(endpoint, "msg_page_#{i}")
          # distinct inserted_at values: nudge the clock-stamped column
          Repo.query!(
            "UPDATE #{@deliveries} SET inserted_at = ? WHERE id = ?",
            [
              DateTime.utc_now() |> DateTime.add(i, :second) |> DateTime.to_iso8601(),
              row.id
            ]
          )

          row
        end

      {:ok, %{records: page, next_cursor: cursor}} =
        AshHooks.Delivery.list(Delivery, endpoint_id: endpoint.id, limit: 2)

      assert [%{id: id5}, %{id: id4}] = page
      assert id5 == Enum.at(rows, 4).id
      assert id4 == Enum.at(rows, 3).id
      assert is_binary(cursor)

      {:ok, %{records: page2, next_cursor: cursor2}} =
        AshHooks.Delivery.list(Delivery,
          endpoint_id: endpoint.id,
          limit: 2,
          after: cursor
        )

      assert [%{id: id3}, %{id: id2}] = page2
      assert id3 == Enum.at(rows, 2).id

      {:ok, %{records: page3, next_cursor: nil}} =
        AshHooks.Delivery.list(Delivery,
          endpoint_id: endpoint.id,
          limit: 2,
          after: cursor2
        )

      assert [%{id: id1}] = page3
      assert id1 == Enum.at(rows, 0).id
    end

    test "attempts filter by endpoint, outcome, and event type with pagination" do
      endpoint = receiver_endpoint!()
      row = pending_row!(endpoint, "msg_attempt_q")

      assert :ok = run!(endpoint, row)

      {:ok, %{records: [attempt]}} =
        AshHooks.OutboundAttempt.list(Attempt, endpoint_id: endpoint.id)

      assert attempt.outcome == :succeeded

      {:ok, %{records: []}} =
        AshHooks.OutboundAttempt.list(Attempt,
          endpoint_id: endpoint.id,
          outcome: [:dead_letter]
        )

      {:ok, %{records: [attempt]}} =
        AshHooks.OutboundAttempt.list(Attempt, event_type: "order_paid")

      {:ok, %{records: []}} =
        AshHooks.OutboundAttempt.list(Attempt,
          from: DateTime.add(DateTime.utc_now(), 60, :second)
        )
    end

    test "a resource without inserted_at fails with the named error" do
      assert {:error, %AshHooks.Errors.Unknown.UnknownError{error: error}} =
               AshHooks.Delivery.list(NoTimestampsDelivery, endpoint_id: Ash.UUID.generate())

      assert error =~ "has no :inserted_at"
    end

    test "a capture-off response path keeps the summary snippet on the attempt" do
      # a 5xx reply: retryable, response-derived summary, capture off — the
      # attempt row carries the summary tuple's snippet
      endpoint = receiver_endpoint!(2, status: 500)
      row = pending_row!(endpoint, "msg_hist_summary")

      assert {:snooze, _delay} = run!(endpoint, row)

      [attempt] = attempts_for(row)
      assert attempt.outcome == :failed_retryable
      assert attempt.reason == "http_500"
      assert attempt.response_snippet == "500 json token=application/json"
      assert attempt.latency_ms != nil
    end

    test "a multibyte body is byte-capped on a UTF-8 boundary" do
      endpoint =
        receiver_endpoint!(2,
          response_capture: true,
          response_capture_max_bytes: 5,
          body: "{\"note\": \"caf\u00e9 \u2713\"}"
        )

      row = pending_row!(endpoint, "msg_hist_utf8_cap")

      assert :ok = run!(endpoint, row)

      [attempt] = attempts_for(row)
      assert String.starts_with?(attempt.response_snippet, "[captured] ")
      # capped at or under 5 bytes, still valid UTF-8 through redaction
      assert byte_size(attempt.response_snippet) <= @snippet_max
    end

    test "a read error on the history query surfaces as an error" do
      endpoint = endpoint!()
      _row = pending_row!(endpoint, "msg_hist_read_error")

      Repo.query!("DROP TABLE IF EXISTS #{@attempts}")

      assert {:error, %Ash.Error.Unknown{}} =
               AshHooks.OutboundAttempt.list(Attempt, endpoint_id: endpoint.id)

      recreate_attempts!()
    end

    test "list defaults: the no-opts call returns everything, and time bounds compose" do
      endpoint = receiver_endpoint!()
      row = pending_row!(endpoint, "msg_hist_list_defaults")
      assert :ok = run!(endpoint, row)

      assert {:ok, %{records: [_]}} = AshHooks.OutboundAttempt.list(Attempt)

      now = DateTime.utc_now()

      assert {:ok, %{records: [_]}} =
               AshHooks.OutboundAttempt.list(Attempt,
                 from: DateTime.add(now, -60, :second),
                 to: DateTime.add(now, 60, :second)
               )

      assert {:ok, %{records: [_]}} =
               AshHooks.Delivery.list(Delivery,
                 endpoint_id: endpoint.id,
                 from: DateTime.add(now, -60, :second),
                 to: DateTime.add(now, 60, :second)
               )

      # a to-bound alone composes too (the {nil, one} arm)
      assert {:ok, %{records: [_]}} =
               AshHooks.OutboundAttempt.list(Attempt, to: DateTime.add(now, 60, :second))
    end

    test "keyset cursor helpers reject non-binaries and non-times" do
      assert {:error, :invalid_cursor} = AshHooks.Delivery.list(Delivery, after: 42)
      assert nil == AshHooks.Keyset.encode_cursor(nil, :inserted_at)
      assert nil == AshHooks.Keyset.encode_cursor(%{inserted_at: "junk", id: 1}, :inserted_at)
    end

    test "a malformed destination policy shape retries under destination_policy_failed" do
      endpoint = endpoint!()
      row = pending_row!(endpoint, "msg_hist_bad_policy")

      assert {:snooze, _} =
               DeliveryRuntime.run(
                 %{"endpoint_id" => endpoint.id, "event_uuid" => row.event_uuid},
                 config(destination_policy: "not-a-policy")
               )

      assert Ash.get!(Delivery, row.id, authorize?: false).last_error ==
               "destination_policy_failed"
    end

    test "a policy that exits or throws is contained" do
      endpoint = endpoint!()

      for kind <- [:exit, :throw] do
        row = pending_row!(endpoint, "msg_hist_policy_#{kind}")

        assert {:snooze, _} =
                 DeliveryRuntime.run(
                   %{"endpoint_id" => endpoint.id, "event_uuid" => row.event_uuid},
                   config(
                     destination_policy: fn _url, _ctx ->
                       case kind do
                         :exit -> exit(:policy_exit)
                         :throw -> throw(:policy_throw)
                       end
                     end
                   )
                 )

        assert Ash.get!(Delivery, row.id, authorize?: false).last_error ==
                 "destination_policy_failed"
      end
    end

    test "a malformed response header entry is dropped, not fatal (unit contract)" do
      # an inline adapter returning a malformed header tuple: the capture
      # filter must drop it without breaking the send (the adapter contract
      # says binary pairs; a custom adapter may violate it)
      endpoint =
        receiver_endpoint!(0, response_capture: true, response_header_allowlist: ["x-want"])

      row = pending_row!(endpoint, "msg_hist_malformed_header")

      assert :ok =
               DeliveryRuntime.run(
                 %{"endpoint_id" => endpoint.id, "event_uuid" => row.event_uuid},
                 config(
                   destination_policy: fn _url, _ctx -> :allow end,
                   http: fn _method, _url, _headers, _body, _opts ->
                     {:ok,
                      %{
                        status: 200,
                        headers: [{"x-want", "yes"}, {123, :malformed}],
                        body: "{}"
                      }}
                   end
                 )
               )

      [attempt] = attempts_for(row)
      assert attempt.response_headers == %{"x-want" => "yes"}
      assert attempt.outcome == :succeeded
    end

    test "a 410 records the disable's terminal attempt with its stored summary" do
      # a public-URL endpoint (castable for the durable disable filter) fed
      # a 410 through an inline adapter: the receiver form cannot serve this
      # arm because its loopback URL cannot re-cast through the endpoint
      # type inside the disable write
      endpoint = endpoint!()
      row = pending_row!(endpoint, "msg_hist_410")

      assert :ok =
               DeliveryRuntime.run(
                 %{"endpoint_id" => endpoint.id, "event_uuid" => row.event_uuid},
                 config(
                   destination_policy: fn _url, _ctx -> :allow end,
                   http: fn _m, _u, _h, _b, _o ->
                     {:ok,
                      %{
                        status: 410,
                        headers: [{"content-type", "application/json"}],
                        body: "gone"
                      }}
                   end
                 )
               )

      final = Ash.get!(Delivery, row.id, authorize?: false)
      assert final.status == :dead_letter
      assert final.last_error == "gone_410"

      [attempt] = attempts_for(row)
      assert attempt.outcome == :dead_letter
      assert attempt.reason == "gone_410"
      assert attempt.response_status == 410

      # the 410 disables the endpoint durably
      assert Ash.get!(Endpoint, endpoint.id, authorize?: false).status == :disabled
    end

    test "prune deletes the attempts WITH their delivery rows" do
      endpoint = receiver_endpoint!(1)
      row = pending_row!(endpoint, "msg_hist_prune")
      assert :ok = run!(endpoint, row)

      # a terminal row + its history, both older than the cutoff
      Repo.query!(
        "UPDATE #{@deliveries} SET status = 'succeeded', inserted_at = '2020-01-01T00:00:00Z' WHERE id = ?",
        [row.id]
      )

      assert {:ok, 1} =
               AshHooks.Delivery.prune(Delivery,
                 older_than: DateTime.utc_now(),
                 attempts: Attempt
               )

      assert Ash.read!(Delivery, authorize?: false) == []
      assert Ash.read!(Attempt, authorize?: false) == []
    end

    test "an out-of-band limit or malformed cursor is a named error" do
      assert {:error, :invalid_limit} = AshHooks.Delivery.list(Delivery, limit: 0)
      assert {:error, :invalid_limit} = AshHooks.OutboundAttempt.list(Attempt, limit: 501)

      assert {:error, :invalid_cursor} =
               AshHooks.Delivery.list(Delivery, after: "not-a-cursor")

      assert {:error, :invalid_cursor} =
               AshHooks.OutboundAttempt.list(Attempt, after: Base.url_encode64("junk"))
    end
  end

  defp recreate_attempts! do
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
  end

  @tag release_fix: 6
  test "release prune rolls back deliveries when deleting history fails" do
    endpoint = endpoint!()
    row = pending_row!(endpoint, "release-prune-history")

    Repo.query!(
      "UPDATE #{@deliveries} SET status = 'dead_letter', inserted_at = '2020-01-01T00:00:00Z' WHERE id = ?",
      [row.id]
    )

    Repo.query!(
      "INSERT INTO #{@attempts} (id, delivery_pk, endpoint_id, event_uuid, event_type, attempt, outcome, attempted_at) VALUES (?, ?, ?, ?, 'order_paid', 1, 'dead_letter', datetime('now'))",
      [Ash.UUID.generate(), Jason.encode!(%{"id" => row.id}), endpoint.id, row.event_uuid]
    )

    Repo.query!(
      "CREATE TRIGGER release_history_abort BEFORE DELETE ON #{@attempts} BEGIN SELECT RAISE(ABORT, 'history retained'); END"
    )

    on_exit(fn -> Repo.query!("DROP TRIGGER IF EXISTS release_history_abort") end)

    assert {:error, _} =
             DeliveryRuntime.prune(Delivery, attempts: Attempt, older_than: DateTime.utc_now())

    assert Ash.get!(Delivery, row.id, authorize?: false).id == row.id
    assert length(attempts_for(row)) == 1
  end
end
