defmodule AshHooks.DeliveryTest do
  @moduledoc """
  The delivery runtime driver (Oban-free by construction — the driver is
  pure functions over resource modules + an injected HTTP adapter; the
  worker macro is tested separately under the Oban-gated module).

  Covers the classification table (design note A10), attempt-before-send
  ordering + durability, the Retry-After/backoff/ceiling transitions, the
  410 durable disable, redirect refusal, send-time SSRF, signing-envelope
  wiring, and snippet redaction.
  """

  defmodule Endpoint do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.DeliveryTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Endpoint]

    sqlite do
      table("delivery_test_endpoints")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read, :create, :update])
      default_accept(:*)
    end
  end

  defmodule Subscription do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.DeliveryTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Subscription]

    sqlite do
      table("delivery_test_subscriptions")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read, :create])
      default_accept(:*)
    end

    subscription do
      endpoint_resource(AshHooks.DeliveryTest.Endpoint)
    end
  end

  defmodule Delivery do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.DeliveryTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundDelivery]

    sqlite do
      table("delivery_test_deliveries")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Emitter do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.DeliveryTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks]

    sqlite do
      table("delivery_test_emitters")
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
        subscriptions(AshHooks.DeliveryTest.Subscription)
        deliveries(AshHooks.DeliveryTest.Delivery)
      end
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(AshHooks.DeliveryTest.Endpoint)
      resource(AshHooks.DeliveryTest.Subscription)
      resource(AshHooks.DeliveryTest.Delivery)
      resource(AshHooks.DeliveryTest.Emitter)
    end
  end

  # HTTP adapter test double: pops queued responses (last one repeats),
  # records every call, and runs an optional on_call hook (the ordering
  # tripwire re-reads the row from inside the adapter).
  defmodule HttpDouble do
    @moduledoc false
    @behaviour AshHooks.Http

    def start_link(responses) do
      Agent.start_link(fn -> {Enum.reverse(responses), [], nil} end, name: __MODULE__)
    end

    def set_responses(responses) do
      Agent.update(__MODULE__, fn {_, calls, _} ->
        {Enum.reverse(responses), calls, nil}
      end)
    end

    def on_call(fun), do: Agent.update(__MODULE__, fn {r, c, _} -> {r, c, fun} end)

    def calls, do: Agent.get(__MODULE__, fn {_, c, _} -> Enum.reverse(c) end)

    @impl true
    def request(method, url, headers, body, opts) do
      # the hook runs in the CALLER (the delivery driver's process) — an
      # on_call raise must surface to the driver's rescue, not kill the agent
      on_call = Agent.get(__MODULE__, fn {_, _, on_call} -> on_call end)
      if on_call, do: on_call.(), else: :ok

      Agent.update(__MODULE__, fn
        {[next | rest], calls, on_call} ->
          rest = if rest == [], do: [next], else: rest

          {rest, [%{method: method, url: url, headers: headers, body: body, opts: opts} | calls],
           on_call}

        {[], calls, on_call} ->
          {[], [%{method: method, url: url, headers: headers, body: body, opts: opts} | calls],
           on_call}
      end)

      {[next | _], _, _} = Agent.get(__MODULE__, fn state -> state end)
      next
    end
  end

  # {m,f} redactor for the raw-body tripwire: tags its INPUT so the test can
  # prove the callback saw the pre-floor body
  defmodule RawShapeRedactor do
    @moduledoc false
    def call(body), do: "raw:" <> body
  end

  # {m,f} secret resolver for the tuple-resolver seam: a compile-time-fixed
  # secret so the test can verify the envelope it produced
  defmodule TupleResolver do
    @moduledoc false
    @resolved "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))
    def call("acme-main"), do: {:ok, @resolved}
    def resolved, do: @resolved
  end

  use ExUnit.Case, async: false

  alias AshHooks.Delivery, as: DeliveryRuntime
  alias AshHooks.{Dispatcher, Event}
  alias AshHooks.Test.Repo

  @endpoints "delivery_test_endpoints"
  @subscriptions "delivery_test_subscriptions"
  @deliveries "delivery_test_deliveries"
  @payload Jason.encode!(%{"order" => 1})
  @secret "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))

  setup_all do
    create_tables!()

    on_exit(fn ->
      Repo.query!("DROP TABLE IF EXISTS #{@deliveries}")
      Repo.query!("DROP TABLE IF EXISTS #{@subscriptions}")
      Repo.query!("DROP TABLE IF EXISTS #{@endpoints}")
    end)

    :ok
  end

  # the drop-injection tests (reconcile failures) drop a table mid-run and
  # must restore the schema before the next test's DELETE FROM
  defp create_tables! do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@endpoints} (
      id TEXT PRIMARY KEY, url TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'enabled',
      secret_ref TEXT NOT NULL, previous_secret_ref TEXT, legacy_secret_ref TEXT,
      legacy_previous_secret_ref TEXT
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@subscriptions} (
      id TEXT PRIMARY KEY, event_types TEXT NOT NULL, endpoint_id TEXT NOT NULL, signing_mode TEXT
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
  end

  setup do
    Repo.query!("DELETE FROM #{@deliveries}")
    Repo.query!("DELETE FROM #{@subscriptions}")
    Repo.query!("DELETE FROM #{@endpoints}")
    {:ok, _} = HttpDouble.start_link([{:ok, %{status: 200, headers: [], body: ~s({"ok": true})}}])
    :ok
  end

  defp endpoint!(url \\ "https://hooks.example.test/accept") do
    Ash.create!(Endpoint, %{url: url, secret_ref: "acme-main"}, authorize?: false)
  end

  defp pending_row!(endpoint, opts \\ []) do
    {:ok, event} = Event.new(type: :order_paid, payload: Keyword.get(opts, :payload, @payload))

    Ash.create!(
      Delivery,
      %{
        event_uuid: event.id,
        event_type: "order_paid",
        payload: event.payload,
        endpoint_id: endpoint.id,
        signing_mode: opts[:signing_mode]
      },
      action: :dispatch,
      authorize?: false
    )
  end

  defp args(row), do: %{"endpoint_id" => row.endpoint_id, "event_uuid" => row.event_uuid}

  defp complete_args(row) do
    %{
      "delivery_pk" => AshHooks.PrimaryKey.encode(row),
      "delivery_resource" => Atom.to_string(Delivery),
      "endpoint_resource" => Atom.to_string(Endpoint),
      "endpoint_id" => row.endpoint_id,
      "event_uuid" => row.event_uuid,
      "dispatch_source" => row.dispatch_source,
      "dispatch_route" => row.dispatch_route
    }
  end

  defp disable_snapshot(endpoint, overrides \\ %{}) do
    Map.merge(
      %{
        "endpoint_pk" => AshHooks.PrimaryKey.encode(endpoint),
        "url" => endpoint.url,
        "secret_ref" => endpoint.secret_ref,
        "previous_secret_ref" => endpoint.previous_secret_ref,
        "legacy_secret_ref" => endpoint.legacy_secret_ref,
        "legacy_previous_secret_ref" => endpoint.legacy_previous_secret_ref,
        "status_attribute" => "status",
        "status_value" => Atom.to_string(endpoint.status)
      },
      overrides
    )
  end

  defp put_disable_pending!(row, snapshot) do
    Repo.query!(
      "UPDATE #{@deliveries} SET status = 'disable_pending', attempts = 1, endpoint_snapshot = ? WHERE id = ?",
      [Jason.encode!(snapshot), row.id]
    )

    row!(row.id)
  end

  defp config(overrides \\ []) do
    now = Keyword.get(overrides, :now)

    [
      deliveries: Delivery,
      endpoints: Endpoint,
      secret_resolver: fn "acme-main" -> {:ok, @secret} end,
      http: HttpDouble,
      max_attempts: 3,
      base_backoff_seconds: 2,
      max_backoff_seconds: 3600,
      retry_after_cap_seconds: 86_400,
      # deterministic literal-only send check (the DNS re-resolution the
      # real default performs is covered by the ssrf suite's :ssrf_dns tag)
      ssrf_check: &AshHooks.Ssrf.registration_safe?/1,
      now: now || fn -> DateTime.utc_now() |> DateTime.truncate(:second) end
    ]
    |> Keyword.merge(overrides)
  end

  defp row!(row_id), do: Ash.get!(Delivery, row_id, authorize?: false)

  describe "success path" do
    test "signs with the row's webhook-id, posts the exact payload, records the response" do
      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok = DeliveryRuntime.run(args(row), config())

      [call] = HttpDouble.calls()
      assert call.method == :post
      assert call.url == ep.url
      assert call.body == @payload
      assert %{"webhook-id" => id} = call.headers
      assert id == row.event_uuid
      assert call.headers["content-type"] == "application/json"

      # the signature verifies against the resolved secret
      assert {:ok, _} =
               AshHooks.Signing.verify(@payload, call.headers, @secret,
                 now: String.to_integer(call.headers["webhook-timestamp"])
               )

      final = row!(row.id)
      assert final.status == :succeeded
      assert final.response_status == 200
      # the default snippet is the NO-BODY summary (#17, ADR-0005 amendment)
      assert final.response_snippet == "200 other token=other"
    end

    test "attempt row BEFORE send: the row is :sending with attempts bumped, durably, when the adapter fires" do
      ep = endpoint!()
      row = pending_row!(ep)
      row_id = row.id
      parent = self()

      HttpDouble.on_call(fn ->
        at_call = row!(row_id)
        send(parent, {:row_at_call, at_call.status, at_call.attempts})
      end)

      assert :ok = DeliveryRuntime.run(args(row), config())

      assert_received {:row_at_call, :sending, 1}
      assert row!(row.id).status == :succeeded
    end

    test "a :succeeded row re-triggered does NOT send again" do
      ep = endpoint!()
      row = pending_row!(ep)
      DeliveryRuntime.run(args(row), config())

      assert :ok = DeliveryRuntime.run(args(row), config())
      assert length(HttpDouble.calls()) == 1
    end
  end

  describe "410 — durable circuit-breaker" do
    test "disables the endpoint AND dead-letters the row" do
      HttpDouble.set_responses([{:ok, %{status: 410, headers: [], body: "Gone"}}])
      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok = DeliveryRuntime.run(args(row), config())

      assert row!(row.id).status == :dead_letter
      assert row!(row.id).last_error =~ "410"
      assert Ash.reload!(ep, authorize?: false).status == :disabled
    end
  end

  describe "408/429/5xx — Retry-After honored (bounded)" do
    test "a 503 carrying an integer Retry-After is honored (the sirtify-routed finding)" do
      # ONE captured timestamp drives both the run and the assertion — a live
      # clock read twice fails across a second boundary (the release review's
      # clock-dependency finding; the 429 test below shares the fix).
      fixed_now = DateTime.utc_now() |> DateTime.truncate(:second)

      HttpDouble.set_responses([
        {:ok, %{status: 503, headers: [{"retry-after", "11"}], body: "overloaded"}}
      ])

      ep = endpoint!()
      row = pending_row!(ep)

      assert {:snooze, 11} = DeliveryRuntime.run(args(row), config(now: fn -> fixed_now end))

      final = row!(row.id)
      assert final.status == :failed_retryable

      assert DateTime.compare(final.next_attempt_at, DateTime.add(fixed_now, 11, :second)) ==
               :eq
    end

    test "a 503 with NO Retry-After still backs off (unchanged)" do
      fixed_now = DateTime.utc_now() |> DateTime.truncate(:second)

      HttpDouble.set_responses([
        {:ok, %{status: 503, headers: [], body: "overloaded"}}
      ])

      ep = endpoint!()
      row = pending_row!(ep)

      # First retryable attempt, post-increment attempts=1: base 2s · 2^1 = 4s
      # plus jitter [0, 4) → the snooze is 4..7, and the persisted schedule
      # matches fixed_now + that snooze.
      assert {:snooze, backoff} = DeliveryRuntime.run(args(row), config(now: fn -> fixed_now end))
      assert backoff in 4..7

      final = row!(row.id)
      assert final.status == :failed_retryable

      assert DateTime.compare(final.next_attempt_at, DateTime.add(fixed_now, backoff, :second)) ==
               :eq
    end

    test "an integer Retry-After sets the schedule and snoozes exactly that long" do
      HttpDouble.set_responses([
        {:ok, %{status: 429, headers: [{"retry-after", "7"}], body: "slow"}}
      ])

      ep = endpoint!()
      row = pending_row!(ep)

      fixed_now = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {:snooze, 7} = DeliveryRuntime.run(args(row), config(now: fn -> fixed_now end))

      final = row!(row.id)
      assert final.status == :failed_retryable

      assert DateTime.compare(final.next_attempt_at, DateTime.add(fixed_now, 7, :second)) ==
               :eq
    end

    test "an HTTP-date Retry-After is honored; an absent one falls back to backoff" do
      fixed_now = DateTime.utc_now() |> DateTime.truncate(:second)
      future = DateTime.add(fixed_now, 30, :second)
      httpdate = Calendar.strftime(future, "%a, %d %b %Y %H:%M:%S GMT")

      HttpDouble.set_responses([
        {:ok, %{status: 429, headers: [{"Retry-After", httpdate}], body: ""}}
      ])

      ep = endpoint!()
      row = pending_row!(ep)

      assert {:snooze, 30} = DeliveryRuntime.run(args(row), config(now: fn -> fixed_now end))
    end

    test "an absurd Retry-After is capped" do
      HttpDouble.set_responses([
        {:ok, %{status: 429, headers: [{"retry-after", "99999999"}], body: ""}}
      ])

      ep = endpoint!()
      row = pending_row!(ep)

      assert {:snooze, 86_400} = DeliveryRuntime.run(args(row), config())
    end

    test "a malformed Retry-After falls back to backoff (not a crash)" do
      HttpDouble.set_responses([
        {:ok, %{status: 429, headers: [{"retry-after", "next tuesday"}], body: ""}}
      ])

      ep = endpoint!()
      row = pending_row!(ep)

      assert {:snooze, delay} = DeliveryRuntime.run(args(row), config())
      assert delay >= 1
    end

    test "a GMT-shaped Retry-After with BAD NUMERICS falls back to backoff (review regression)" do
      HttpDouble.set_responses([
        {:ok,
         %{status: 429, headers: [{"retry-after", "Mon, 32 Jan 2026 25:61:61 GMT"}], body: ""}}
      ])

      ep = endpoint!()
      row = pending_row!(ep)

      assert {:snooze, delay} = DeliveryRuntime.run(args(row), config())
      assert delay >= 4
    end
  end

  describe "Ash 3.33 counting-mode regressions" do
    # Under the test app's :codepoints config (Ash 3.33's required choice),
    # the injected response_snippet constraint counts CODEPOINTS — and a
    # grapheme-sliced 2048 snippet of combining characters spans 4000+
    # codepoints, failing the post-send ledger write on its own constraint
    # (the same re-send poison class the control-byte strip closes). Found
    # by mining a timed-out cross-vendor probe; the byte cap bounds the
    # snippet in every counting mode.
    test "a combining-character body still records its captured snippet" do
      HttpDouble.set_responses([
        {:ok, %{status: 200, headers: [], body: String.duplicate("à́", 3000)}}
      ])

      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok = DeliveryRuntime.run(args(row), config(snippet_capture: true))

      snippet = row!(row.id).response_snippet
      assert String.starts_with?(snippet, "[captured] ")
      assert String.valid?(snippet)
      assert byte_size(snippet) <= 2048
      assert snippet |> String.to_charlist() |> length() <= 2048
    end
  end

  describe "cross-vendor review regressions (2)" do
    test "a PERCENT-ENCODED secret disguise is redacted (derisk review regression)" do
      HttpDouble.set_responses([
        {:ok,
         %{
           status: 200,
           headers: [],
           body: ~s({"e": "%77hsec_) <> "dGVzdHNlY3JldDEyMzQ1Njc4OTA" <> ~s(", "ok": 1})
         }}
      ])

      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok = DeliveryRuntime.run(args(row), config(snippet_capture: true))

      snippet = row!(row.id).response_snippet
      assert String.starts_with?(snippet, "[captured] ")
      refute snippet =~ "77hsec"
      refute snippet =~ "dGVzdHNlY3JldDEyMzQ1Njc4OTA"
      assert snippet =~ "[redacted]"
    end

    test "a JSON-\\u-ESCAPED secret disguise is redacted (derisk-2 regression)" do
      with_escapes =
        "{\"e\": \"whsec_\\u0064\\u0054\\u0056\\u007a\\u0064\\u0048\\u004e\\u006c\\u0059\\u0033\\u004a\\u006c\\u0064\\u0044\\u0065\\u0079\\u004a\\u007a\\u0051\\u0033\\u004e\\u006a\\u0063\\u0034\\u004f\\u0054\\u0041\\u003d\", \"ok\": 1}"

      HttpDouble.set_responses([{:ok, %{status: 200, headers: [], body: with_escapes}}])

      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok = DeliveryRuntime.run(args(row), config(snippet_capture: true))

      snippet = row!(row.id).response_snippet
      assert String.starts_with?(snippet, "[captured] ")
      refute snippet =~ "u0064"
      refute snippet =~ "whsec_"
      assert snippet =~ "[redacted]"
    end

    test "a DOUBLE-PERCENT-ENCODED secret disguise is redacted (derisk-2 regression)" do
      # "%2577hsec_..." decodes twice to "%77hsec_..." then to "whsec_..."
      body = ~s({"e": "%2577hsec_) <> "c2VjcmV0LXNoaW0tdGVzdC1rZXkxMg" <> ~s(})

      HttpDouble.set_responses([{:ok, %{status: 200, headers: [], body: body}}])

      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok = DeliveryRuntime.run(args(row), config(snippet_capture: true))

      snippet = row!(row.id).response_snippet
      assert String.starts_with?(snippet, "[captured] ")
      refute snippet =~ "2577hsec"
      assert snippet =~ "[redacted]"
    end

    test "an ADAPTER pin-time SSRF refusal dead-letters immediately (never burns the ceiling)" do
      refusing = fn _method, _url, _headers, _body, _opts -> {:error, :unsafe_destination} end

      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok = DeliveryRuntime.run(args(row), config(http: refusing, max_attempts: 50))
      assert HttpDouble.calls() == []

      final = row!(row.id)
      assert final.status == :dead_letter
      assert final.attempts == 1
      assert final.last_error =~ "unsafe_destination"
    end

    test "an endpoint READ ERROR retries; only a GONE endpoint dead-letters" do
      ep = endpoint!()
      row = pending_row!(ep)
      Repo.query!("DROP TABLE #{@endpoints}")

      assert {:error, _reason} = DeliveryRuntime.run(args(row), config())
      assert HttpDouble.calls() == []

      Repo.query!("""
      CREATE TABLE #{@endpoints} (
        id TEXT PRIMARY KEY, url TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'enabled',
        secret_ref TEXT NOT NULL, previous_secret_ref TEXT, legacy_secret_ref TEXT,
        legacy_previous_secret_ref TEXT
      )
      """)
    end

    test "an :enqueue_failed row re-driven by the runtime dead-letters pre-send when disabled" do
      ep = endpoint!()
      Ash.update!(ep, %{}, action: :disable, authorize?: false)

      row =
        Ash.create!(
          Delivery,
          %{
            event_uuid: "msg_enq_failed_predl",
            event_type: "order_paid",
            payload: @payload,
            endpoint_id: ep.id
          },
          action: :dispatch,
          authorize?: false
        )

      Repo.query!("UPDATE #{@deliveries} SET status = 'enqueue_failed' WHERE id = ?", [row.id])

      assert :ok = DeliveryRuntime.run(args(row), config())
      assert row!(row.id).status == :dead_letter
      assert row!(row.id).last_error =~ "endpoint_disabled"
    end
  end

  describe "backoff, ceiling, dead-letter" do
    test "5xx retries with exponential jittered backoff within [delay, 2*delay]" do
      HttpDouble.set_responses([{:ok, %{status: 500, headers: [], body: "oops"}}])
      ep = endpoint!()
      row = pending_row!(ep)

      assert {:snooze, delay} = DeliveryRuntime.run(args(row), config())

      # attempts == 1 after the mark: base 2 * 2^1 = 4; jitter adds [0, delay)
      assert delay >= 4 and delay <= 8
      assert row!(row.id).status == :failed_retryable
    end

    test "the ceiling dead-letters and stops (run returns :ok — no infinite snooze)" do
      HttpDouble.set_responses([{:ok, %{status: 500, headers: [], body: "oops"}}])
      ep = endpoint!()
      row = pending_row!(ep)
      max_2 = config(max_attempts: 2)

      {:snooze, _} = DeliveryRuntime.run(args(row), max_2)

      late = fn -> DateTime.add(DateTime.utc_now(), 3600) end
      assert :ok = DeliveryRuntime.run(args(row), Keyword.put(max_2, :now, late))

      final = row!(row.id)
      assert final.status == :dead_letter
      assert final.attempts == 2
    end

    test "a not-yet-due failed row snoozes to its slot without sending" do
      HttpDouble.set_responses([
        {:ok, %{status: 429, headers: [{"retry-after", "60"}], body: ""}}
      ])

      ep = endpoint!()
      row = pending_row!(ep)
      {:snooze, 60} = DeliveryRuntime.run(args(row), config())

      # still exactly ONE adapter call — the re-drive waits for its slot
      # (60s or 59s if a second elapsed since the schedule was written)
      assert {:snooze, remaining} = DeliveryRuntime.run(args(row), config())
      assert remaining in 59..60
      assert length(HttpDouble.calls()) == 1
    end

    test "transport errors retry with backoff" do
      HttpDouble.set_responses([{:error, :econnrefused}])
      ep = endpoint!()
      row = pending_row!(ep)

      assert {:snooze, delay} = DeliveryRuntime.run(args(row), config())
      assert delay >= 4
      assert row!(row.id).status == :failed_retryable
      assert row!(row.id).last_error =~ "econnrefused"
    end
  end

  describe "redirect + client-error terminality" do
    test "a 302 is refused (never followed) and dead-letters immediately" do
      HttpDouble.set_responses([
        {:ok, %{status: 302, headers: [{"location", "https://evil.test/x"}], body: ""}}
      ])

      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok = DeliveryRuntime.run(args(row), config())

      assert length(HttpDouble.calls()) == 1
      assert row!(row.id).status == :dead_letter
      assert row!(row.id).last_error =~ "redirect"
    end

    test "a plain 404 dead-letters (client errors do not burn the retry ceiling)" do
      HttpDouble.set_responses([{:ok, %{status: 404, headers: [], body: "nope"}}])
      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok = DeliveryRuntime.run(args(row), config())
      assert row!(row.id).status == :dead_letter
      assert row!(row.id).last_error =~ "404"
    end
  end

  describe "send-time SSRF (registration was clean; the destination went private)" do
    test "a url that flipped to a private literal after registration dead-letters without sending" do
      ep = endpoint!()
      row = pending_row!(ep)

      Repo.query!("UPDATE #{@endpoints} SET url = 'http://127.0.0.1:8080/x' WHERE id = ?", [ep.id])

      assert :ok = DeliveryRuntime.run(args(row), config())
      assert HttpDouble.calls() == []
      assert row!(row.id).status == :dead_letter
      assert row!(row.id).last_error =~ "destination"
    end
  end

  describe "endpoint state at send" do
    test "a disabled endpoint dead-letters the row without sending" do
      ep = endpoint!()
      Ash.update!(ep, %{}, action: :disable, authorize?: false)
      row = pending_row!(ep)

      assert :ok = DeliveryRuntime.run(args(row), config())
      assert HttpDouble.calls() == []
      assert row!(row.id).status == :dead_letter
    end
  end

  describe "signing envelope wiring" do
    test ":dual mode emits BOTH envelopes using the legacy ref" do
      legacy = "legacy-incumbent-secret"

      cfg =
        config(
          secret_resolver: fn
            "acme-main" -> {:ok, @secret}
            "legacy" -> {:ok, legacy}
          end
        )

      Repo.query!("UPDATE #{@endpoints} SET legacy_secret_ref = 'legacy' WHERE id = ?", [
        endpoint!().id
      ])

      ep = Ash.read!(Endpoint, authorize?: false) |> hd()
      row = pending_row!(ep, signing_mode: :dual)

      assert :ok = DeliveryRuntime.run(args(row), cfg)

      [call] = HttpDouble.calls()
      assert call.headers["webhook-signature"] =~ "v1,"
      assert call.headers["x-webhook-signature"] =~ "t="

      # the legacy envelope verifies against the incumbent verifier (the oracle)
      sig = call.headers["x-webhook-signature"]
      "t=" <> ts_str = hd(String.split(sig, ","))
      ts = String.to_integer(ts_str)
      assert {:ok, _} = AshHooks.Legacy.verify(legacy, @payload, sig, ts, 300)
    end
  end

  describe "secret resolution failure" do
    test "a resolver error retries (config is fixable), does not dead-letter early" do
      cfg = config(secret_resolver: fn _ -> {:error, :vault_down} end)
      ep = endpoint!()
      row = pending_row!(ep)

      assert {:snooze, _delay} = DeliveryRuntime.run(args(row), cfg)
      assert row!(row.id).status == :failed_retryable
      assert HttpDouble.calls() == []
    end
  end

  describe "response snippet redaction (the floor lives on the CAPTURED path post-#17)" do
    test "secret-shaped material never lands in a CAPTURED snippet" do
      leaky =
        ~s({"leak": "whsec_) <>
          Base.encode64(:crypto.strong_rand_bytes(32)) <>
          ~s(", bearer": "Bearer abcdef1234567890abcdef", "b64": ") <>
          Base.encode64(:crypto.strong_rand_bytes(48)) <> ~s(", "ok": 1})

      HttpDouble.set_responses([{:ok, %{status: 200, headers: [], body: leaky}}])
      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok = DeliveryRuntime.run(args(row), config(snippet_capture: true))

      snippet = row!(row.id).response_snippet
      assert String.starts_with?(snippet, "[captured] ")
      refute snippet =~ "whsec_"
      refute snippet =~ "Bearer abcdef"
      assert snippet =~ "[redacted]"
    end
  end

  describe "summarize/2 — the no-body default (#17)" do
    test "kind + token classification: allowlisted types pass, everything else is other" do
      assert DeliveryRuntime.summarize(200, [{"content-type", "text/html; charset=utf-8"}]) ==
               "200 html token=text/html"

      assert DeliveryRuntime.summarize(201, [{"Content-Type", "application/vnd.api+json"}]) ==
               "201 json token=other"

      assert DeliveryRuntime.summarize(502, [{"content-type", "image/png"}]) ==
               "502 binary token=other"

      assert DeliveryRuntime.summarize(200, []) == "200 other token=other"
      assert DeliveryRuntime.summarize(nil, nil) == "0 other token=other"
    end

    test "capture-off: a leaky body persists ONLY the fixed-grammar summary — no body bytes" do
      secret = Base.encode64(:crypto.strong_rand_bytes(32))

      leaky = ~s({"leak": "whsec_) <> secret <> ~s(", "b64": ") <> secret <> ~s(", "ok": 1})

      HttpDouble.set_responses([
        {:ok,
         %{
           status: 200,
           headers: [{"content-type", "application/json; charset=utf-8"}],
           body: leaky
         }}
      ])

      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok = DeliveryRuntime.run(args(row), config())

      assert row!(row.id).response_snippet == "200 json token=application/json"
    end

    test "capture-off: a hostile content-type cannot smuggle material into the token" do
      HttpDouble.set_responses([
        {:ok,
         %{
           status: 200,
           headers: [{"Content-Type", "text/whsec_SUPERSECRETTOKEN42"}],
           body: "whatever"
         }}
      ])

      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok = DeliveryRuntime.run(args(row), config())

      snippet = row!(row.id).response_snippet
      assert snippet == "200 text token=other"
      refute snippet =~ "SUPERSECRETTOKEN"
    end
  end

  describe "opt-in capture under the floor (#17)" do
    test "a captured snippet carries the marker with the floor-redacted body" do
      HttpDouble.set_responses([
        {:ok,
         %{
           status: 200,
           headers: [{"content-type", "application/json"}],
           body: ~s({"ok": true, "note": "diagnostic"})
         }}
      ])

      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok = DeliveryRuntime.run(args(row), config(snippet_capture: true))

      snippet = row!(row.id).response_snippet
      assert String.starts_with?(snippet, "[captured] ")
      assert snippet =~ "diagnostic"
    end

    test "a base32 secret below the OLD 20-char floor dies (the ≥16 union rule)" do
      base32 = "mfzwizltozsa2atofzw"
      body = ~s({"e": ") <> base32 <> ~s(", "ok": 1})

      HttpDouble.set_responses([{:ok, %{status: 200, headers: [], body: body}}])

      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok = DeliveryRuntime.run(args(row), config(snippet_capture: true))

      snippet = row!(row.id).response_snippet
      refute snippet =~ base32
      assert snippet =~ "[redacted]"
    end

    test "a fullwidth homoglyph marker dies (NFKC head)" do
      body = ~s({"e": "ｗｈｓｅｃ_) <> "dGVzdHNlY3Jl" <> ~s(", "ok": 1})

      HttpDouble.set_responses([{:ok, %{status: 200, headers: [], body: body}}])

      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok = DeliveryRuntime.run(args(row), config(snippet_capture: true))

      snippet = row!(row.id).response_snippet
      refute snippet =~ "ｗｈｓｅｃ"
      refute snippet =~ "dGVzdHNlY3Jl"
      assert snippet =~ "[redacted]"
    end

    test "a PERCENT-ENCODED fullwidth marker dies (NFKC after the decode chain)" do
      # %EF%BD%97… decodes to ｗｈｓｅｃ only AFTER percent decoding — the head
      # normalization alone would leave the marker fullwidth
      body = "token=%EF%BD%97%EF%BD%88%EF%BD%93%EF%BD%85%EF%BD%83_dGVzdHNlY3Jl"

      HttpDouble.set_responses([{:ok, %{status: 200, headers: [], body: body}}])

      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok = DeliveryRuntime.run(args(row), config(snippet_capture: true))

      snippet = row!(row.id).response_snippet
      refute snippet =~ "dGVzdHNlY3Jl"
      assert snippet =~ "[redacted]"
    end

    test "a json-materialized percent evasion dies (decode-chain fixpoint)" do
      # \u0025 → % materializes AFTER the percent layers have run — only a
      # fixpoint re-run decodes the resulting %77 to 'w'
      body = "{\"e\": \"\\u002577hsec_ab12cd\", \"ok\": 1}"

      HttpDouble.set_responses([{:ok, %{status: 200, headers: [], body: body}}])

      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok = DeliveryRuntime.run(args(row), config(snippet_capture: true))

      snippet = row!(row.id).response_snippet
      refute snippet =~ "77hsec"
      refute snippet =~ "ab12cd"
      assert snippet =~ "[redacted]"
    end

    test "a +-bearing base64 token redacts WHOLE (no www-form +→space split)" do
      body = "{\"e\": \"whsec_abc+def+ghi+jkl\", \"ok\": 1}"

      HttpDouble.set_responses([{:ok, %{status: 200, headers: [], body: body}}])

      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok = DeliveryRuntime.run(args(row), config(snippet_capture: true))

      snippet = row!(row.id).response_snippet
      refute snippet =~ "whsec"
      refute snippet =~ "ghi"
      assert snippet =~ "[redacted]"
    end

    test "split markers with ≤3 separators die" do
      # short materials + non-union delimiters isolate the MARKER-separator
      # property — a ≥16 union run would die to entropy regardless
      body = "x: whs-ec ab12cd, y: wh-sk 12ab34, z: whs.ec 98ba76"

      HttpDouble.set_responses([{:ok, %{status: 200, headers: [], body: body}}])

      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok = DeliveryRuntime.run(args(row), config(snippet_capture: true))

      snippet = row!(row.id).response_snippet
      refute snippet =~ "ab12cd"
      refute snippet =~ "12ab34"
      refute snippet =~ "98ba76"
      assert snippet =~ "[redacted]"
    end

    test "whsk_ and whpk_ secrets die like whsec_ (cross-vendor fix-pass regression)" do
      body =
        ~s({"sk": "whsk_) <>
          "skmat12345" <> ~s(", "pk": "whpk_) <> "pkmat67890" <> ~s(", "ok": 1})

      HttpDouble.set_responses([{:ok, %{status: 200, headers: [], body: body}}])

      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok = DeliveryRuntime.run(args(row), config(snippet_capture: true))

      snippet = row!(row.id).response_snippet
      refute snippet =~ "whsk"
      refute snippet =~ "whpk"
      refute snippet =~ "skmat"
      refute snippet =~ "pkmat"
      assert snippet =~ "[redacted]"
    end

    test "a form-encoded Bearer+token dies (cross-vendor fix-pass regression)" do
      # 15 contiguous union chars — under the entropy floor; only the
      # marker's + separator tolerance catches it
      HttpDouble.set_responses([
        {:ok, %{status: 200, headers: [], body: "auth: Bearer+tok12345, ok"}}
      ])

      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok = DeliveryRuntime.run(args(row), config(snippet_capture: true))

      snippet = row!(row.id).response_snippet
      refute snippet =~ "tok12345"
      assert snippet =~ "[redacted]"
    end

    test "a %-escape that would materialize invalid UTF-8 never leaves the floor (cross-vendor fix-pass)" do
      HttpDouble.set_responses([
        {:ok, %{status: 200, headers: [], body: ~s({"x": "%FF%FE junk"})}}
      ])

      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok = DeliveryRuntime.run(args(row), config(snippet_capture: true))

      snippet = row!(row.id).response_snippet
      assert String.valid?(snippet)
      # the raw bytes must not have materialized; the literal ASCII text may
      refute snippet =~ "\xFF"
    end

    test "a ≥16 union run dies with no marker at all; a 15-char run survives" do
      body = ~s({"long": "abcdefghijklmnop", "short": "abcdefghijklmno", "ok": 1})

      HttpDouble.set_responses([{:ok, %{status: 200, headers: [], body: body}}])

      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok = DeliveryRuntime.run(args(row), config(snippet_capture: true))

      snippet = row!(row.id).response_snippet
      refute snippet =~ "abcdefghijklmnop"
      assert snippet =~ "abcdefghijklmno"
    end

    test "Cyrillic prose passes the floor untouched (no cross-script folding)" do
      prose = "Привет, мир! Это обычный текст без секретов."
      body = ~s({"note": ") <> prose <> ~s(", "ok": 1})

      HttpDouble.set_responses([{:ok, %{status: 200, headers: [], body: body}}])

      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok = DeliveryRuntime.run(args(row), config(snippet_capture: true))

      assert row!(row.id).response_snippet =~ prose
    end

    test "invalid UTF-8 persists a binary placeholder, never the raw bytes" do
      body = <<0xFF, ?a, ?b, ?c, 0xFE, ?x>>

      HttpDouble.set_responses([{:ok, %{status: 200, headers: [], body: body}}])

      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok = DeliveryRuntime.run(args(row), config(snippet_capture: true))

      assert row!(row.id).response_snippet == "[captured] [binary]"
    end

    test "a CRASHING snippet_redactor degrades to the sanitized summary (fail-closed)" do
      HttpDouble.set_responses([
        {:ok,
         %{
           status: 200,
           headers: [{"content-type", "application/json"}],
           body: ~s({"e": "whsec_abcdef123456"})
         }}
      ])

      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok =
               DeliveryRuntime.run(
                 args(row),
                 config(
                   snippet_capture: true,
                   snippet_redactor: fn _body -> raise "consumer boom" end
                 )
               )

      # crash → the sanitized summary: no marker, no body bytes, no crash
      assert row!(row.id).response_snippet == "200 json token=application/json"
    end

    test "an INVALID snippet_redactor return degrades to the sanitized summary" do
      HttpDouble.set_responses([
        {:ok, %{status: 200, headers: [{"content-type", "text/plain"}], body: "plain"}}
      ])

      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok =
               DeliveryRuntime.run(
                 args(row),
                 config(snippet_capture: true, snippet_redactor: fn _body -> {:ok, "shaped"} end)
               )

      assert row!(row.id).response_snippet == "200 text token=text/plain"
    end

    test "a NIL snippet_redactor return degrades to the sanitized summary" do
      HttpDouble.set_responses([
        {:ok, %{status: 200, headers: [], body: "plain"}}
      ])

      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok =
               DeliveryRuntime.run(
                 args(row),
                 config(snippet_capture: true, snippet_redactor: fn _body -> nil end)
               )

      assert row!(row.id).response_snippet == "200 other token=other"
    end

    test "an {m,f} snippet_redactor sees the RAW body; its output lands under the floor" do
      HttpDouble.set_responses([
        {:ok, %{status: 200, headers: [], body: ~s({"e": "whsec_abcdef12345"})}}
      ])

      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok =
               DeliveryRuntime.run(
                 args(row),
                 config(snippet_capture: true, snippet_redactor: {RawShapeRedactor, :call})
               )

      snippet = row!(row.id).response_snippet
      # the callback received the RAW (pre-floor) body and its output still
      # passed the package floor — defense in depth
      assert String.starts_with?(snippet, "[captured] raw:")
      refute snippet =~ "whsec_"
      assert snippet =~ "[redacted]"
    end

    test "an oversized snippet_redactor output is floor-truncated within the 2048 cap" do
      HttpDouble.set_responses([{:ok, %{status: 200, headers: [], body: "x"}}])

      ep = endpoint!()
      row = pending_row!(ep)

      # dot-separated filler: oversized, but union runs of 1 — it must
      # SURVIVE the floor (a plain 10k union run would be [redacted])
      filler = String.duplicate("D.", 5_000)

      assert :ok =
               DeliveryRuntime.run(
                 args(row),
                 config(
                   snippet_capture: true,
                   snippet_redactor: fn _body -> filler end
                 )
               )

      snippet = row!(row.id).response_snippet
      assert String.starts_with?(snippet, "[captured] ")
      assert String.contains?(snippet, "D.D")
      assert String.length(snippet) <= 2048
    end
  end

  describe "failure rows carry the summary (#17)" do
    test "a 4xx failure row records the status and the no-body summary" do
      HttpDouble.set_responses([
        {:ok,
         %{
           status: 404,
           headers: [{"content-type", "text/plain"}],
           body: "nope whsec_leakymaterial1"
         }}
      ])

      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok = DeliveryRuntime.run(args(row), config())

      final = row!(row.id)
      assert final.status == :dead_letter
      assert final.response_status == 404
      assert final.response_snippet == "404 text token=text/plain"
    end
  end

  describe "raw-miniserver e2e through the default adapter (#17)" do
    test "a captured delivery through Bounded persists the marker + redacted body" do
      secret = "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(16))
      body = ~s({"echo": ") <> secret <> ~s(", "ok": true})

      response =
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: " <>
          Integer.to_string(byte_size(body)) <> "\r\nconnection: close\r\n\r\n" <> body

      parent = self()

      {:ok, listen} = :gen_tcp.listen(0, [:binary, {:active, false}, {:ip, {127, 0, 0, 1}}])
      {:ok, port} = :inet.port(listen)

      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listen, 10_000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)
        :gen_tcp.send(socket, response)
        :timer.sleep(200)
        :gen_tcp.close(socket)
        :gen_tcp.close(listen)
        send(parent, :served)
      end)

      ep = endpoint!()

      Repo.query!("UPDATE #{@endpoints} SET url = ? WHERE id = ?", [
        "http://127.0.0.1:#{port}/hook",
        ep.id
      ])

      row = pending_row!(ep)

      assert :ok =
               DeliveryRuntime.run(
                 args(row),
                 config(
                   snippet_capture: true,
                   http: AshHooks.Http.Bounded,
                   http_opts: [validate_destination: false],
                   ssrf_check: fn _url -> true end
                 )
               )

      assert_receive :served, 2_000

      final = row!(row.id)
      assert final.status == :succeeded
      snippet = final.response_snippet
      assert String.starts_with?(snippet, "[captured] ")
      refute snippet =~ secret
      assert snippet =~ "[redacted]"
    end
  end

  describe "the dispatcher persists the effective signing mode (#6 extension)" do
    test "subscription override lands on the row; default is :standard when unset" do
      ep = endpoint!()

      Ash.create!(
        Subscription,
        %{endpoint_id: ep.id, event_types: ["order_paid"], signing_mode: :dual},
        authorize?: false
      )

      {:ok, event} = Event.new(type: :order_paid, payload: @payload)
      {:ok, _} = Dispatcher.dispatch(Emitter, :order_paid, event)

      assert hd(Ash.read!(Delivery, authorize?: false)).signing_mode == :dual
    end
  end

  # ────────────────── coverage: fetch/gate/reconcile arms ──────────────────

  describe "row fetch arms" do
    test "args without ids are a completed delivery (:ok, no send)" do
      assert :ok = DeliveryRuntime.run(%{}, config())
      assert HttpDouble.calls() == []
    end

    test "ids matching no row are :missing — the durable row is the record" do
      assert :ok =
               DeliveryRuntime.run(
                 %{"endpoint_id" => Ash.UUID.generate(), "event_uuid" => Ash.UUID.generate()},
                 config()
               )

      assert HttpDouble.calls() == []
    end

    test "a row read that errors surfaces the error" do
      on_exit(fn -> create_tables!() end)
      Repo.query!("DROP TABLE #{@deliveries}")

      assert {:error, _reason} =
               DeliveryRuntime.run(
                 %{"endpoint_id" => "ep", "event_uuid" => "ev"},
                 config()
               )

      create_tables!()
    end

    test "complete job identity rejects malformed keys and partial legacy identity" do
      ep = endpoint!()
      row = pending_row!(ep)

      assert {:error, :invalid_primary_key} =
               DeliveryRuntime.run(%{"delivery_pk" => %{"id" => "not-a-uuid"}}, config())

      assert {:error, :invalid_delivery_identity} =
               DeliveryRuntime.run(%{"endpoint_id" => ep.id}, config())

      assert row!(row.id).status == :pending
      assert HttpDouble.calls() == []
    end

    test "complete job metadata is checked against the stored delivery before send" do
      ep = endpoint!()
      row = pending_row!(ep)
      bound_source = AshHooks.OutboundBinding.direct_source(Delivery, Endpoint)

      Repo.query!("UPDATE #{@deliveries} SET dispatch_source = ? WHERE id = ?", [
        bound_source,
        row.id
      ])

      row = row!(row.id)
      job = complete_args(row)

      assert {:error, :worker_resource_mismatch} =
               DeliveryRuntime.run(%{job | "delivery_resource" => "Wrong.Delivery"}, config())

      assert {:error, :worker_resource_mismatch} =
               DeliveryRuntime.run(%{job | "endpoint_resource" => "Wrong.Endpoint"}, config())

      assert {:error, :dispatch_source_conflict} =
               DeliveryRuntime.run(%{job | "dispatch_source" => "v1:source:wrong"}, config())

      assert {:error, :dispatch_route_conflict} =
               DeliveryRuntime.run(%{job | "dispatch_route" => "v1:route:wrong"}, config())

      assert {:error, :dispatch_route_conflict} =
               DeliveryRuntime.run(job, config(dispatch_route: "v1:route:wrong"))

      assert row!(row.id).status == :pending
      assert HttpDouble.calls() == []
    end

    test "a stored source bound to another endpoint resource fails closed" do
      ep = endpoint!()
      row = pending_row!(ep)

      other_source =
        AshHooks.OutboundBinding.direct_source(Delivery, AshHooks.WorkerTest.Endpoint)

      Repo.query!("UPDATE #{@deliveries} SET dispatch_source = ? WHERE id = ?", [
        other_source,
        row.id
      ])

      row = row!(row.id)

      assert {:error, :endpoint_resource_mismatch} =
               DeliveryRuntime.run(complete_args(row), config())

      assert row!(row.id).status == :pending
      assert HttpDouble.calls() == []
    end

    test "direct source binding reports a lost or rejected compare-and-set" do
      for {trigger_action, expected} <- [
            {"SELECT RAISE(IGNORE)", :dispatch_source_conflict},
            {"SELECT RAISE(ABORT, 'blocked source binding')", :storage_error}
          ] do
        ep = endpoint!()
        row = pending_row!(ep)

        Repo.query!("""
        CREATE TRIGGER delivery_block_source_binding
        BEFORE UPDATE OF dispatch_source ON #{@deliveries}
        WHEN OLD.dispatch_source = 'v1:direct:unbound'
        BEGIN
          #{trigger_action};
        END
        """)

        result = DeliveryRuntime.run(args(row), config())

        case expected do
          :dispatch_source_conflict -> assert {:error, :dispatch_source_conflict} = result
          :storage_error -> assert {:error, %Ash.Error.Unknown{}} = result
        end

        Repo.query!("DROP TRIGGER delivery_block_source_binding")
        assert row!(row.id).status == :pending
      end

      assert HttpDouble.calls() == []
    end
  end

  describe "a gone endpoint" do
    test "a row whose endpoint was deleted dead-letters as endpoint_gone" do
      ep = endpoint!()
      row = pending_row!(ep)
      Repo.query!("DELETE FROM #{@endpoints} WHERE id = ?", [ep.id])

      assert :ok = DeliveryRuntime.run(args(row), config())

      final = row!(row.id)
      assert final.status == :dead_letter
      assert final.last_error == "endpoint_gone"
      assert HttpDouble.calls() == []
    end
  end

  describe "a contended row" do
    test "a result fenced out by a concurrent transition snoozes without overwriting it" do
      ep = endpoint!()
      row = pending_row!(ep)

      # Flip the row after this executor owns the attempt but before the
      # adapter runs. The external request may happen, but its result cannot
      # overwrite the concurrent terminal transition.
      contending =
        Keyword.put(config(), :ssrf_check, fn _url ->
          Repo.query!("UPDATE #{@deliveries} SET status = 'succeeded' WHERE id = ?", [row.id])
          true
        end)

      assert {:snooze, 1} = DeliveryRuntime.run(args(row), contending)

      assert length(HttpDouble.calls()) == 1
      assert row!(row.id).status == :succeeded
    end

    test "a lost or rejected send claim never reaches the adapter" do
      for {trigger_action, expected} <- [
            {"SELECT RAISE(IGNORE)", {:snooze, 1}},
            {"SELECT RAISE(ABORT, 'blocked send claim')", :storage_error}
          ] do
        ep = endpoint!()
        row = pending_row!(ep)

        Repo.query!("""
        CREATE TRIGGER delivery_block_send_claim
        BEFORE UPDATE OF status ON #{@deliveries}
        WHEN OLD.status = 'pending' AND NEW.status = 'sending'
        BEGIN
          #{trigger_action};
        END
        """)

        result = DeliveryRuntime.run(args(row), config())

        case expected do
          {:snooze, 1} -> assert {:snooze, 1} = result
          :storage_error -> assert {:error, %Ash.Error.Unknown{}} = result
        end

        Repo.query!("DROP TRIGGER delivery_block_send_claim")
        assert row!(row.id).status == :pending
      end

      assert HttpDouble.calls() == []
    end

    test "retry and dead-letter writes cannot overwrite a concurrent terminal state" do
      ep = endpoint!()
      retry_row = pending_row!(ep)

      retry_resolver = fn _ref ->
        Repo.query!("UPDATE #{@deliveries} SET status = 'succeeded' WHERE id = ?", [retry_row.id])
        {:error, :vault_down}
      end

      assert {:snooze, 1} =
               DeliveryRuntime.run(args(retry_row), config(secret_resolver: retry_resolver))

      assert row!(retry_row.id).status == :succeeded

      dead_row = pending_row!(ep)

      check = fn _url ->
        Repo.query!("UPDATE #{@deliveries} SET status = 'succeeded' WHERE id = ?", [dead_row.id])
        false
      end

      assert {:snooze, 1} = DeliveryRuntime.run(args(dead_row), config(ssrf_check: check))
      assert row!(dead_row.id).status == :succeeded
      assert HttpDouble.calls() == []
    end
  end

  describe "driver deadline and send lease" do
    test "the configured application clock is evaluated inside the monitored deadline" do
      ep = endpoint!()
      row = pending_row!(ep)
      parent = self()

      clock = fn ->
        send(parent, :clock_entered)
        Process.sleep(500)
        send(parent, :clock_finished)
        DateTime.utc_now()
      end

      assert {:error, :attempt_timeout} =
               DeliveryRuntime.run(
                 args(row),
                 config(now: clock, attempt_timeout: 50, finalization_allowance: 50)
               )

      assert_received :clock_entered
      refute_receive :clock_finished, 100
      assert row!(row.id).status == :pending
      assert HttpDouble.calls() == []
    end

    test "an exhausted finalization allowance returns without waiting for process shutdown" do
      ep = endpoint!()
      row = pending_row!(ep)

      clock = fn ->
        Process.sleep(500)
        DateTime.utc_now()
      end

      started = System.monotonic_time(:millisecond)

      assert {:error, :finalization_timeout} =
               DeliveryRuntime.run(
                 args(row),
                 config(now: clock, attempt_timeout: 25, finalization_allowance: 0)
               )

      assert System.monotonic_time(:millisecond) - started < 250
      assert row!(row.id).status == :pending
      assert HttpDouble.calls() == []
    end

    test "the deadline bounds delivery-row preflight while the real SQLite pool is occupied" do
      ep = endpoint!()
      row = pending_row!(ep)
      parent = self()

      holder =
        spawn(fn ->
          Repo.transaction(fn ->
            send(parent, :preflight_pool_occupied)
            Process.sleep(400)
          end)
        end)

      assert_receive :preflight_pool_occupied, 1_000
      started = System.monotonic_time(:millisecond)

      assert {:error, :attempt_timeout} =
               DeliveryRuntime.run(
                 args(row),
                 config(attempt_timeout: 50, finalization_allowance: 50)
               )

      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed < 250
      assert HttpDouble.calls() == []

      ref = Process.monitor(holder)
      assert_receive {:DOWN, ^ref, :process, ^holder, :normal}, 1_000
    end

    test "timeout cleanup is bounded by the finalization allowance under SQLite write contention" do
      ep = endpoint!()
      row = pending_row!(ep)
      parent = self()

      run =
        Task.async(fn ->
          DeliveryRuntime.run(
            args(row),
            config(
              now: &DateTime.utc_now/0,
              attempt_timeout: 500,
              finalization_allowance: 100,
              ssrf_check: fn _url ->
                send(parent, {:claimed_preflight, self()})

                receive do
                  :continue_after_lock -> true
                end
              end
            )
          )
        end)

      assert_receive {:claimed_preflight, driver}, 1_000

      holder =
        spawn(fn ->
          Repo.transaction(fn ->
            Repo.query!("UPDATE #{@deliveries} SET attempts = attempts WHERE id = ?", [row.id])
            send(parent, :finalization_write_locked)
            Process.sleep(1_000)
          end)
        end)

      assert_receive :finalization_write_locked, 1_000
      started = System.monotonic_time(:millisecond)
      send(driver, :continue_after_lock)

      assert {:error, :finalization_timeout} = Task.await(run, 2_000)
      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed < 800

      ref = Process.monitor(holder)
      assert_receive {:DOWN, ^ref, :process, ^holder, :normal}, 2_000

      stranded = row!(row.id)
      assert stranded.status == :sending
      assert stranded.attempts == 1
      assert is_binary(stranded.attempt_token)
      assert HttpDouble.calls() |> length() == 1
    end

    test "the monitored deadline includes secret-resolution preflight and kills late work" do
      ep = endpoint!()
      row = pending_row!(ep)
      parent = self()

      resolver = fn "acme-main" ->
        send(parent, :resolver_entered)
        Process.sleep(1_500)
        send(parent, :resolver_finished)
        {:ok, @secret}
      end

      assert {:snooze, delay} =
               DeliveryRuntime.run(
                 args(row),
                 config(
                   secret_resolver: resolver,
                   now: &DateTime.utc_now/0,
                   attempt_timeout: 500,
                   finalization_allowance: 1_000
                 )
               )

      assert delay >= 1
      assert_received :resolver_entered
      refute_receive :resolver_finished, 100

      final = row!(row.id)
      assert final.status == :failed_retryable
      assert final.attempts == 1
      assert final.last_error == "attempt_timeout"
      assert final.send_lease_expires_at == nil
      assert HttpDouble.calls() == []
    end

    test "an abnormal monitored-process exit after claim is fenced into retry state" do
      ep = endpoint!()
      row = pending_row!(ep)

      assert {:snooze, delay} =
               DeliveryRuntime.run(
                 args(row),
                 config(ssrf_check: fn _url -> throw(:preflight_crash) end)
               )

      assert delay >= 1
      final = row!(row.id)
      assert final.status == :failed_retryable
      assert final.attempts == 1
      assert final.last_error == "driver_crash"
      assert final.send_lease_expires_at == nil
      assert HttpDouble.calls() == []
    end

    test "a crashing bounded finalizer returns finalization_crash and leaves the claim recoverable" do
      ep = endpoint!()
      row = pending_row!(ep)
      clock_owners = :ets.new(:delivery_clock_owners, [:set, :public])

      clock = fn ->
        case :ets.lookup(clock_owners, :driver) do
          [] ->
            true = :ets.insert_new(clock_owners, {:driver, self()})
            DateTime.utc_now() |> DateTime.truncate(:second)

          [{:driver, pid}] when pid == self() ->
            DateTime.utc_now() |> DateTime.truncate(:second)

          [{:driver, _pid}] ->
            raise "finalizer clock failed"
        end
      end

      assert {:error, {:finalization_crash, "unclassified"}} =
               DeliveryRuntime.run(
                 args(row),
                 config(now: clock, ssrf_check: fn _url -> throw(:driver_failed) end)
               )

      final = row!(row.id)
      assert final.status == :sending
      assert final.attempts == 1
      assert is_binary(final.attempt_token)
      assert HttpDouble.calls() == []
    end

    test "application-clock lease expiry protects a live final attempt, then terminalizes it" do
      ep = endpoint!()
      row = pending_row!(ep)
      base = DateTime.utc_now() |> DateTime.truncate(:second)
      lease = DateTime.add(base, 120, :second)
      token = Ash.UUID.generate()
      handler = {__MODULE__, make_ref()}

      :ok =
        :telemetry.attach_many(
          handler,
          [
            [:ash_hooks, :delivery, :result],
            [:ash_hooks, :delivery, :dead_letter]
          ],
          fn event, _measurements, metadata, owner -> send(owner, {event, metadata}) end,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      Repo.query!(
        "UPDATE #{@deliveries} SET status = 'sending', attempts = 3, attempt_token = ?, send_lease_expires_at = ? WHERE id = ?",
        [token, DateTime.to_iso8601(lease), row.id]
      )

      assert {:snooze, seconds} =
               DeliveryRuntime.run(args(row), config(now: fn -> base end))

      assert seconds >= 119
      live = row!(row.id)
      assert live.status == :sending
      assert live.attempts == 3
      assert live.attempt_token == token

      after_lease = DateTime.add(lease, 30, :second)
      assert :ok = DeliveryRuntime.run(args(row), config(now: fn -> after_lease end))

      final = row!(row.id)
      assert final.status == :dead_letter
      assert final.attempts == 3
      assert final.last_error == "attempt_ceiling"
      assert HttpDouble.calls() == []

      assert_received {[:ash_hooks, :delivery, :result],
                       %{status: :dead_letter, reason: "attempt_ceiling"}}

      assert_received {[:ash_hooks, :delivery, :dead_letter],
                       %{reason: "attempt_ceiling", response_status: nil}}
    end
  end

  describe "an adapter crash" do
    test "a raising adapter classifies as a retryable transport failure" do
      ep = endpoint!()
      row = pending_row!(ep)

      HttpDouble.on_call(fn -> raise ArgumentError, "adapter exploded" end)

      assert {:snooze, _delay} = DeliveryRuntime.run(args(row), config())

      final = row!(row.id)
      assert final.status == :failed_retryable
      assert final.last_error == "adapter_crash"
    end
  end

  describe "reconcile failures surface (never swallowed)" do
    test "a failed mark_succeeded returns the error for a job retry" do
      ep = endpoint!()
      row = pending_row!(ep)

      on_exit(fn -> create_tables!() end)
      HttpDouble.on_call(fn -> Repo.query!("DROP TABLE #{@deliveries}") end)

      assert {:error, {:reconcile_failed, _reason}} =
               DeliveryRuntime.run(args(row), config())

      create_tables!()
    end

    test "a failed mark_send_failed on the retry path returns the error" do
      ep = endpoint!()
      row = pending_row!(ep)

      HttpDouble.set_responses([{:ok, %{status: 429, headers: []}}])
      on_exit(fn -> create_tables!() end)
      HttpDouble.on_call(fn -> Repo.query!("DROP TABLE #{@deliveries}") end)

      assert {:error, {:reconcile_failed, _reason}} = DeliveryRuntime.run(args(row), config())

      create_tables!()
    end

    test "a failed dead-letter write returns the error" do
      ep = endpoint!()
      row = pending_row!(ep)

      HttpDouble.set_responses([{:ok, %{status: 404, headers: []}}])
      on_exit(fn -> create_tables!() end)
      HttpDouble.on_call(fn -> Repo.query!("DROP TABLE #{@deliveries}") end)

      assert {:error, {:reconcile_failed, _reason}} = DeliveryRuntime.run(args(row), config())

      create_tables!()
    end

    test "a failed durable disable on 410 surfaces :disable_failed" do
      ep = endpoint!()
      row = pending_row!(ep)

      HttpDouble.set_responses([{:ok, %{status: 410, headers: []}}])
      on_exit(fn -> create_tables!() end)
      HttpDouble.on_call(fn -> Repo.query!("DROP TABLE #{@endpoints}") end)

      assert {:error, {:disable_failed, _other}} = DeliveryRuntime.run(args(row), config())

      create_tables!()
    end
  end

  describe "secret resolution shapes" do
    test "an {m, f} resolver tuple resolves through apply/3" do
      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok =
               DeliveryRuntime.run(args(row), config(secret_resolver: {TupleResolver, :call}))

      [call] = HttpDouble.calls()

      assert {:ok, _} =
               AshHooks.Signing.verify(@payload, call.headers, TupleResolver.resolved(),
                 now: String.to_integer(call.headers["webhook-timestamp"])
               )
    end

    test "a resolver returning an invalid shape is a secret_resolution failure (retryable)" do
      ep = endpoint!()
      row = pending_row!(ep)

      assert {:snooze, _delay} =
               DeliveryRuntime.run(
                 args(row),
                 config(secret_resolver: fn _ref -> {:ok, nil} end)
               )

      assert row!(row.id).last_error == "secret_resolution"
    end

    test "invalid, raising, exiting, and throwing resolvers become bounded retry reasons" do
      resolvers = [
        :invalid,
        fn _ref -> raise "secret payload" end,
        fn _ref -> exit(:secret_payload) end,
        fn _ref -> throw(:secret_payload) end
      ]

      for resolver <- resolvers do
        ep = endpoint!()
        row = pending_row!(ep)

        assert {:snooze, delay} =
                 DeliveryRuntime.run(args(row), config(secret_resolver: resolver))

        assert delay >= 1
        assert row!(row.id).last_error == "secret_resolution"
      end

      assert HttpDouble.calls() == []
    end

    test "an endpoint with an empty secret_ref fails :no_secret (retryable, fixable)" do
      ep_id = Ash.UUID.generate()

      Repo.query!(
        "INSERT INTO #{@endpoints} (id, url, status, secret_ref) VALUES (?, ?, 'enabled', '')",
        [ep_id, "https://hooks.example.test/accept"]
      )

      row = pending_row!(%{id: ep_id})

      assert {:snooze, _delay} = DeliveryRuntime.run(args(row), config())
      assert row!(row.id).last_error == "no_secret"
    end
  end

  describe "durable disable recovery" do
    test "a stored obligation disables the unchanged endpoint and finalizes the delivery" do
      ep = endpoint!()
      row = ep |> pending_row!() |> put_disable_pending!(disable_snapshot(ep))

      assert :ok = DeliveryRuntime.run(args(row), config())
      assert Ash.reload!(ep, authorize?: false).status == :disabled
      assert row!(row.id).status == :dead_letter
      assert row!(row.id).last_error == "gone_410"
      assert HttpDouble.calls() == []
    end

    test "gone, reconfigured, and already-disabled endpoints finalize without a send" do
      gone = endpoint!()
      gone_row = gone |> pending_row!() |> put_disable_pending!(disable_snapshot(gone))
      Repo.query!("DELETE FROM #{@endpoints} WHERE id = ?", [gone.id])

      assert :ok = DeliveryRuntime.run(args(gone_row), config())
      assert row!(gone_row.id).last_error == "gone_410_endpoint_gone"

      changed = endpoint!()
      changed_row = changed |> pending_row!() |> put_disable_pending!(disable_snapshot(changed))

      Repo.query!("UPDATE #{@endpoints} SET url = ? WHERE id = ?", [
        "https://hooks.example.test/changed",
        changed.id
      ])

      assert :ok = DeliveryRuntime.run(args(changed_row), config())
      assert row!(changed_row.id).last_error == "gone_410_endpoint_reconfigured"

      disabled = endpoint!()
      Ash.update!(disabled, %{}, action: :disable, authorize?: false)
      disabled = Ash.reload!(disabled, authorize?: false)

      disabled_row =
        disabled
        |> pending_row!()
        |> put_disable_pending!(disable_snapshot(disabled))

      assert :ok = DeliveryRuntime.run(args(disabled_row), config())
      assert row!(disabled_row.id).last_error == "gone_410_endpoint_already_disabled"
      assert HttpDouble.calls() == []
    end

    test "invalid snapshots and status mappings surface bounded recovery results" do
      ep = endpoint!()
      invalid_pk = ep |> pending_row!() |> put_disable_pending!(%{"endpoint_pk" => %{}})

      assert {:error, {:disable_failed, :primary_key_mismatch}} =
               DeliveryRuntime.run(args(invalid_pk), config())

      mapped = endpoint!()

      mapped_row =
        mapped
        |> pending_row!()
        |> put_disable_pending!(disable_snapshot(mapped, %{"status_attribute" => "other"}))

      assert :ok = DeliveryRuntime.run(args(mapped_row), config())
      assert row!(mapped_row.id).last_error == "gone_410_endpoint_reconfigured"
      assert HttpDouble.calls() == []
    end

    test "a zero-match endpoint disable is reread and reported as changed" do
      ep = endpoint!()
      row = ep |> pending_row!() |> put_disable_pending!(disable_snapshot(ep))

      Repo.query!("""
      CREATE TRIGGER delivery_ignore_endpoint_disable
      BEFORE UPDATE OF status ON #{@endpoints}
      WHEN OLD.status = 'enabled' AND NEW.status = 'disabled'
      BEGIN
        SELECT RAISE(IGNORE);
      END
      """)

      on_exit(fn -> Repo.query!("DROP TRIGGER IF EXISTS delivery_ignore_endpoint_disable") end)

      assert {:error, {:disable_failed, :endpoint_changed}} =
               DeliveryRuntime.run(args(row), config())

      assert Ash.reload!(ep, authorize?: false).status == :enabled
      assert row!(row.id).status == :disable_pending
      assert HttpDouble.calls() == []
    end

    test "zero-match disable recovery observes a concurrently gone or reconfigured endpoint" do
      for {trigger_body, expected} <- [
            {"DELETE FROM #{@endpoints} WHERE id = OLD.id", "gone_410_endpoint_gone"},
            {"UPDATE #{@endpoints} SET url = 'https://hooks.example.test/reconfigured' WHERE id = OLD.id",
             "gone_410_endpoint_reconfigured"},
            {"UPDATE #{@endpoints} SET status = 'disabled' WHERE id = OLD.id",
             "gone_410_endpoint_already_disabled"}
          ] do
        ep = endpoint!()
        row = ep |> pending_row!() |> put_disable_pending!(disable_snapshot(ep))

        Repo.query!("""
        CREATE TRIGGER delivery_change_endpoint_during_disable
        BEFORE UPDATE OF status ON #{@endpoints}
        WHEN OLD.status = 'enabled' AND NEW.status = 'disabled'
        BEGIN
          #{trigger_body};
          SELECT RAISE(IGNORE);
        END
        """)

        assert :ok = DeliveryRuntime.run(args(row), config())
        assert row!(row.id).last_error == expected
        Repo.query!("DROP TRIGGER delivery_change_endpoint_during_disable")
      end

      assert HttpDouble.calls() == []
    end

    test "all configured endpoint references participate in the conditional disable" do
      ep =
        Ash.create!(
          Endpoint,
          %{
            url: "https://hooks.example.test/accept",
            secret_ref: "current",
            previous_secret_ref: "previous",
            legacy_secret_ref: "legacy",
            legacy_previous_secret_ref: "legacy-previous"
          },
          authorize?: false
        )

      row = ep |> pending_row!() |> put_disable_pending!(disable_snapshot(ep))

      assert :ok = DeliveryRuntime.run(args(row), config())
      assert Ash.reload!(ep, authorize?: false).status == :disabled
      assert row!(row.id).last_error == "gone_410"
      assert HttpDouble.calls() == []
    end

    test "a rejected endpoint disable preserves the recoverable obligation" do
      ep = endpoint!()
      row = ep |> pending_row!() |> put_disable_pending!(disable_snapshot(ep))

      Repo.query!("""
      CREATE TRIGGER delivery_reject_endpoint_disable
      BEFORE UPDATE OF status ON #{@endpoints}
      WHEN OLD.status = 'enabled' AND NEW.status = 'disabled'
      BEGIN
        SELECT RAISE(ABORT, 'blocked endpoint disable');
      END
      """)

      on_exit(fn -> Repo.query!("DROP TRIGGER IF EXISTS delivery_reject_endpoint_disable") end)

      assert {:error, {:disable_failed, %Ash.Error.Unknown{}}} =
               DeliveryRuntime.run(args(row), config())

      assert row!(row.id).status == :disable_pending
      assert HttpDouble.calls() == []
    end

    test "a stale or rejected finalization keeps the disable obligation recoverable" do
      for {trigger_action, expected} <- [
            {"SELECT RAISE(IGNORE)", {:disable_failed, :stale_disable_obligation}},
            {"SELECT RAISE(ABORT, 'blocked finalization')", :storage_error}
          ] do
        ep = endpoint!()
        row = ep |> pending_row!() |> put_disable_pending!(disable_snapshot(ep))

        Repo.query!("""
        CREATE TRIGGER delivery_block_disable_finalize
        BEFORE UPDATE OF status ON #{@deliveries}
        WHEN OLD.status = 'disable_pending' AND NEW.status = 'dead_letter'
        BEGIN
          #{trigger_action};
        END
        """)

        result = DeliveryRuntime.run(args(row), config())

        case expected do
          {:disable_failed, reason} -> assert {:error, {:disable_failed, ^reason}} = result
          :storage_error -> assert {:error, {:disable_failed, %Ash.Error.Unknown{}}} = result
        end

        Repo.query!("DROP TRIGGER delivery_block_disable_finalize")
        assert row!(row.id).status == :disable_pending
      end

      assert HttpDouble.calls() == []
    end
  end

  describe "attempt ceiling compare-and-set" do
    test "pending and due retry rows terminalize without sending" do
      ep = endpoint!()

      for {status, event_id} <- [
            {"pending", "ceiling-pending"},
            {"enqueue_failed", "ceiling-enqueue-failed"},
            {"failed_retryable", "ceiling-retry"}
          ] do
        row = pending_row!(ep)

        Repo.query!(
          "UPDATE #{@deliveries} SET event_uuid = ?, status = ?, attempts = 3, next_attempt_at = NULL WHERE id = ?",
          [event_id, status, row.id]
        )

        row = row!(row.id)
        assert :ok = DeliveryRuntime.run(args(row), config())
        assert row!(row.id).status == :dead_letter
        assert row!(row.id).last_error == "attempt_ceiling"
      end

      assert HttpDouble.calls() == []
    end

    test "a lost or rejected terminal claim leaves the exhausted row recoverable" do
      for {trigger_action, expected} <- [
            {"SELECT RAISE(IGNORE)", {:snooze, 1}},
            {"SELECT RAISE(ABORT, 'blocked ceiling')", :storage_error}
          ] do
        ep = endpoint!()
        row = pending_row!(ep)
        Repo.query!("UPDATE #{@deliveries} SET attempts = 3 WHERE id = ?", [row.id])

        Repo.query!("""
        CREATE TRIGGER delivery_block_ceiling
        BEFORE UPDATE OF status ON #{@deliveries}
        WHEN NEW.status = 'dead_letter'
        BEGIN
          #{trigger_action};
        END
        """)

        result = DeliveryRuntime.run(args(row), config())

        case expected do
          {:snooze, 1} -> assert {:snooze, 1} = result
          :storage_error -> assert {:error, %Ash.Error.Unknown{}} = result
        end

        Repo.query!("DROP TRIGGER delivery_block_ceiling")
        assert row!(row.id).status == :pending
      end

      assert HttpDouble.calls() == []
    end

    test "an expired sending lease is reclaimed through the sending-state fence" do
      ep = endpoint!()
      row = pending_row!(ep)
      past = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.to_iso8601()

      Repo.query!(
        "UPDATE #{@deliveries} SET status = 'sending', attempts = 1, attempt_token = ?, send_lease_expires_at = ? WHERE id = ?",
        [Ash.UUID.generate(), past, row.id]
      )

      row = row!(row.id)
      assert :ok = DeliveryRuntime.run(args(row), config(ssrf_check: fn _url -> false end))
      assert row!(row.id).status == :dead_letter
      assert row!(row.id).attempts == 2
      assert HttpDouble.calls() == []
    end
  end

  describe "signing option wiring" do
    test "a whsk_-prefixed base secret signs through the whsk slot (v1a)" do
      {whsk, whpk} = AshHooks.Signing.generate_signing_keypair()

      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok =
               DeliveryRuntime.run(
                 args(row),
                 config(secret_resolver: fn "acme-main" -> {:ok, whsk} end)
               )

      [call] = HttpDouble.calls()

      assert {:ok, _} =
               AshHooks.Signing.verify(@payload, call.headers, whpk,
                 now: String.to_integer(call.headers["webhook-timestamp"])
               )
    end

    test "previous_secret_ref resolves into the previous slots (whsk and whsec)" do
      for prefix <- ["whsk_", "whsec_"] do
        ep =
          Ash.create!(
            Endpoint,
            %{
              url: "https://hooks.example.test/accept",
              secret_ref: "acme-main",
              previous_secret_ref: "acme-prev"
            },
            authorize?: false
          )

        row = pending_row!(ep)

        assert :ok =
                 DeliveryRuntime.run(
                   args(row),
                   config(
                     secret_resolver: fn
                       "acme-main" ->
                         {:ok, @secret}

                       "acme-prev" ->
                         {:ok, prefix <> Base.encode64(:crypto.strong_rand_bytes(32))}
                     end
                   )
                 )

        assert row!(row.id).status == :succeeded
      end
    end

    test "legacy plus legacy_previous refs emit the dual envelope off both" do
      legacy = "legacy-secret-material-1"
      legacy_prev = "legacy-secret-material-0"

      ep =
        Ash.create!(
          Endpoint,
          %{
            url: "https://hooks.example.test/accept",
            secret_ref: "acme-main",
            legacy_secret_ref: "acme-legacy",
            legacy_previous_secret_ref: "acme-legacy-prev"
          },
          authorize?: false
        )

      Ash.create!(
        Subscription,
        %{endpoint_id: ep.id, event_types: ["order_paid"], signing_mode: :dual},
        authorize?: false
      )

      {:ok, event} = Event.new(type: :order_paid, payload: @payload)
      {:ok, _} = Dispatcher.dispatch(Emitter, :order_paid, event)
      row = hd(Ash.read!(Delivery, authorize?: false))

      assert :ok =
               DeliveryRuntime.run(
                 args(row),
                 config(
                   secret_resolver: fn
                     "acme-main" -> {:ok, @secret}
                     "acme-legacy" -> {:ok, legacy}
                     "acme-legacy-prev" -> {:ok, legacy_prev}
                   end
                 )
               )

      [call] = HttpDouble.calls()
      assert call.headers["x-webhook-signature"]
      assert call.headers["webhook-signature"]
    end

    test "a :legacy row without a legacy ref is a caught :signing_failed retry" do
      ep = endpoint!()

      row =
        Ash.create!(
          Delivery,
          %{
            event_uuid: Ash.UUID.generate(),
            event_type: "order_paid",
            payload: @payload,
            endpoint_id: ep.id,
            signing_mode: :legacy
          },
          action: :dispatch,
          authorize?: false
        )

      assert {:snooze, _delay} = DeliveryRuntime.run(args(row), config())
      assert row!(row.id).last_error == "signing_failed"
    end
  end

  describe "the Retry-After grammar" do
    @now ~U[2026-01-01 00:00:00Z]
    @day 86_400

    defp retry_run(header_value) do
      ep = endpoint!()
      row = pending_row!(ep)

      HttpDouble.set_responses([
        {:ok, %{status: 429, headers: [{"retry-after", header_value}]}}
      ])

      result =
        DeliveryRuntime.run(
          args(row),
          config(now: fn -> @now end, retry_after_cap_seconds: 100_000_000)
        )

      {result, row!(row.id)}
    end

    test "every RFC-1123 month parses to its exact day offset" do
      # 2026-01-01 is a Thursday; the weekday token is not validated by design
      months = [
        {"Feb", 31},
        {"Mar", 59},
        {"Apr", 90},
        {"May", 120},
        {"Jun", 151},
        {"Jul", 181},
        {"Aug", 212},
        {"Sep", 243},
        {"Oct", 273},
        {"Nov", 304},
        {"Dec", 334}
      ]

      for {month, days} <- months do
        expected = days * @day
        assert {{:snooze, ^expected}, _row} = retry_run("Thu, 01 #{month} 2026 00:00:00 GMT")
      end
    end

    test "an unknown month name falls back to backoff" do
      assert {{:snooze, delay}, _row} = retry_run("Thu, 01 Xyz 2026 00:00:00 GMT")
      assert delay in 4..7
    end

    test "an ISO-8601 Retry-After parses" do
      expected = 31 * @day
      assert {{:snooze, ^expected}, _row} = retry_run("2026-02-01T00:00:00Z")
    end

    test "a malformed hms shape falls back to backoff" do
      assert {{:snooze, delay}, _row} = retry_run("Thu, 01 Jan 2026 1200 GMT")
      assert delay in 4..7
    end

    test "a non-integer hms component falls back to backoff" do
      assert {{:snooze, delay}, _row} = retry_run("Thu, 01 Jan 2026 12x:00:00 GMT")
      assert delay in 4..7
    end

    test "a 429 with NO retry-after header falls back to backoff" do
      ep = endpoint!()
      row = pending_row!(ep)

      HttpDouble.set_responses([{:ok, %{status: 429, headers: [{"content-type", "text/plain"}]}}])

      assert {:snooze, delay} = DeliveryRuntime.run(args(row), config())
      assert delay in 4..7
    end

    test "a 429 response with no headers at all falls back to backoff" do
      ep = endpoint!()
      row = pending_row!(ep)

      HttpDouble.set_responses([{:ok, %{status: 429}}])

      assert {:snooze, delay} = DeliveryRuntime.run(args(row), config())
      assert delay in 4..7
      assert row!(row.id).last_error == "http_429"
    end
  end

  describe "summarize/2 kind vocabulary (binary family)" do
    test "octet-stream is allowlisted binary" do
      assert DeliveryRuntime.summarize(200, [{"content-type", "application/octet-stream"}]) ==
               "200 binary token=application/octet-stream"
    end

    test "image/, audio/, video/, and bare application/ types are unallowlisted binary" do
      for type <- ["image/png", "audio/ogg", "video/mp4", "application/foo"] do
        assert DeliveryRuntime.summarize(200, [{"content-type", type}]) ==
                 "200 binary token=other"
      end
    end

    test "an unmatched type family is :other" do
      assert DeliveryRuntime.summarize(200, [{"content-type", "foo/bar"}]) ==
               "200 other token=other"
    end
  end

  describe "redact/1 edges" do
    test "a non-binary body redacts to nil (no snippet)" do
      assert DeliveryRuntime.redact(nil) == nil
      assert DeliveryRuntime.redact(42) == nil
    end

    test "a malformed percent escape never raises and never materializes invalid UTF-8" do
      # "%E0%A4%A" — an incomplete escape URI.decode would raise on; the
      # floor keeps the input as-is instead
      assert DeliveryRuntime.redact("token %E0%A4%A tail") == "token %E0%A4%A tail"
    end

    test "a surrogate \\u escape keeps its escape form instead of aborting the layer" do
      kept = DeliveryRuntime.redact("a \\uD800 b")

      assert kept =~ "\\uD800"
      assert kept =~ "a"
    end

    test "a deeply layered disguise exhausts the decode bound, not the memory" do
      # 20 %-layers over a marker-bearing seed — each pass strips two; the
      # fixpoint's 8-pass bound is the brake, so material survives the
      # decode layers and still dies to the marker pattern
      layered =
        Enum.reduce(1..20, "tok%25n whsec_material1", fn _, acc ->
          String.replace(acc, "%", "%25")
        end)

      assert String.contains?(layered, "%")
      reddited = DeliveryRuntime.redact(layered)
      assert reddited =~ "[redacted]"
    end
  end

  describe "snippet redactor fault classes" do
    test "an EXITING snippet_redactor degrades to the sanitized summary" do
      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok =
               DeliveryRuntime.run(
                 args(row),
                 config(snippet_capture: true, snippet_redactor: fn _body -> exit(:boom) end)
               )

      assert row!(row.id).response_snippet == "200 other token=other"
    end

    test "a THROWING snippet_redactor degrades to the sanitized summary" do
      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok =
               DeliveryRuntime.run(
                 args(row),
                 config(snippet_capture: true, snippet_redactor: fn _body -> throw(:x) end)
               )

      assert row!(row.id).response_snippet == "200 other token=other"
    end
  end
end
