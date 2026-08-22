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
      Agent.get(__MODULE__, fn {_, _, on_call} -> if on_call, do: on_call.(), else: :ok end)

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

  use ExUnit.Case, async: false

  alias AshHooks.Delivery, as: DeliveryRuntime
  alias AshHooks.{Dispatcher, Event}
  alias AshHooks.Test.Repo

  require Ash.Query

  @endpoints "delivery_test_endpoints"
  @subscriptions "delivery_test_subscriptions"
  @deliveries "delivery_test_deliveries"
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
      response_snippet TEXT, last_error TEXT, next_attempt_at TEXT
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@deliveries}_unique_delivery_index ON #{@deliveries} (endpoint_id, event_uuid)"
    )

    on_exit(fn ->
      Repo.query!("DROP TABLE IF EXISTS #{@deliveries}")
      Repo.query!("DROP TABLE IF EXISTS #{@subscriptions}")
      Repo.query!("DROP TABLE IF EXISTS #{@endpoints}")
    end)

    :ok
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

  describe "408/429 — Retry-After honored (bounded)" do
    test "an integer Retry-After sets the schedule and snoozes exactly that long" do
      HttpDouble.set_responses([
        {:ok, %{status: 429, headers: [{"retry-after", "7"}], body: "slow"}}
      ])

      ep = endpoint!()
      row = pending_row!(ep)

      assert {:snooze, 7} = DeliveryRuntime.run(args(row), config())

      final = row!(row.id)
      assert final.status == :failed_retryable

      assert DateTime.compare(final.next_attempt_at, DateTime.add(config()[:now].(), 7, :second)) ==
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
      body = "a=whs-ec_dGVzdHNlY3Jl b=whs.ec 1234567890ab"

      HttpDouble.set_responses([{:ok, %{status: 200, headers: [], body: body}}])

      ep = endpoint!()
      row = pending_row!(ep)

      assert :ok = DeliveryRuntime.run(args(row), config(snippet_capture: true))

      snippet = row!(row.id).response_snippet
      refute snippet =~ "dGVzdHNlY3Jl"
      refute snippet =~ "1234567890ab"
      assert snippet =~ "[redacted]"
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
end
