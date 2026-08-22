defmodule AshHooks.TelemetryTest do
  @moduledoc """
  The telemetry surface (#11): every spec-named event fires with the
  ADR-0005 floor — ids, integers, fixed atoms, classified reasons only;
  NEVER secrets, bodies, or payloads. Non-vacuity is mutation-proven
  (per-event emit removal reds its assertion; the error_string floor's
  removal reds the no-secret tripwire).
  """

  defmodule Endpoint do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.TelemetryTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Endpoint]

    sqlite do
      table("telemetry_test_endpoints")
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
      domain: AshHooks.TelemetryTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundDelivery]

    sqlite do
      table("telemetry_test_deliveries")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Ledger do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.TelemetryTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks, AshHooks.InboundDelivery]

    sqlite do
      table("telemetry_test_ledgers")
      repo(AshHooks.Test.Repo)
    end

    inbound_delivery do
      scope_identity([:account_id])
    end

    attributes do
      attribute(:account_id, :string, allow_nil?: false)
    end

    actions do
      defaults([:read])
    end

    webhooks do
      inbound :counter do
        provider(AshHooks.CountingProvider)
        secret {AshHooks.TelemetryTest, :secret, []}
        event_id(&__MODULE__.event_id/1)
      end
    end

    def event_id(%{"id" => id}) when is_binary(id), do: {:ok, id}
    def event_id(_payload), do: :error
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(AshHooks.TelemetryTest.Endpoint)
      resource(AshHooks.TelemetryTest.Delivery)
      resource(AshHooks.TelemetryTest.Ledger)
    end
  end

  # pops queued responses (last repeats), like delivery_test's double
  defmodule HttpDouble do
    @moduledoc false
    @behaviour AshHooks.Http

    def start_link(responses) do
      Agent.start_link(fn -> Enum.reverse(responses) end, name: __MODULE__)
    end

    def set_responses(responses) do
      Agent.update(__MODULE__, fn _ -> Enum.reverse(responses) end)
    end

    @impl true
    def request(_method, _url, _headers, _body, _opts) do
      [next | rest] = Agent.get(__MODULE__, & &1)
      Agent.update(__MODULE__, fn _ -> if(rest == [], do: [next], else: rest) end)
      next
    end
  end

  use ExUnit.Case, async: false

  alias AshHooks.Delivery, as: DeliveryRuntime
  alias AshHooks.Ingress
  alias AshHooks.Test.Repo

  @endpoints "telemetry_test_endpoints"
  @deliveries "telemetry_test_deliveries"
  @ledgers "telemetry_test_ledgers"
  @secret "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))
  @ingress_secret "ingress-test-secret"

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
      response_snippet TEXT, last_error TEXT, next_attempt_at TEXT
    )
    """)

    Repo.query!("""
    CREATE UNIQUE INDEX IF NOT EXISTS #{@deliveries}_unique_delivery_index ON #{@deliveries} (endpoint_id, event_uuid)
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@ledgers} (
      id TEXT PRIMARY KEY, provider TEXT NOT NULL, external_event_id TEXT NOT NULL,
      external_event_type TEXT, payload TEXT NOT NULL, payload_digest TEXT NOT NULL,
      status TEXT NOT NULL, fencing_token INTEGER NOT NULL DEFAULT 0,
      lease_expires_at TEXT, error_class TEXT, attempts INTEGER NOT NULL DEFAULT 0,
      account_id TEXT NOT NULL
    )
    """)

    Repo.query!("""
    CREATE UNIQUE INDEX IF NOT EXISTS #{@ledgers}_unique_ingest_index ON #{@ledgers} (provider, external_event_id, account_id)
    """)

    on_exit(fn ->
      Repo.query!("DROP TABLE IF EXISTS #{@ledgers}")
      Repo.query!("DROP TABLE IF EXISTS #{@deliveries}")
      Repo.query!("DROP TABLE IF EXISTS #{@endpoints}")
    end)

    :ok
  end

  setup do
    Repo.query!("DELETE FROM #{@deliveries}")
    Repo.query!("DELETE FROM #{@endpoints}")
    Repo.query!("DELETE FROM #{@ledgers}")

    # the counting provider is global — reset per test (the claim test
    # flips the outcome; without the reset it leaks into the siblings)
    AshHooks.CountingProvider.put_sink(self())
    AshHooks.CountingProvider.put_outcome(:ok)
    on_exit(&AshHooks.CountingProvider.cleanup/0)

    {:ok, _} = HttpDouble.start_link([{:ok, %{status: 200, headers: [], body: ~s({"ok": true})}}])

    parent = self()
    handler_id = "telemetry-test-#{System.unique_integer()}"

    # execute/3 matches EXACT names in telemetry 1.4 — attach_many over
    # the package's full event list (probed; prefix attach never fires)
    :telemetry.attach_many(
      handler_id,
      [
        [:ash_hooks, :ingress, :verify],
        [:ash_hooks, :ingress, :dedup],
        [:ash_hooks, :ingress, :claim],
        [:ash_hooks, :dispatch, :enqueue_failed],
        [:ash_hooks, :delivery, :attempt],
        [:ash_hooks, :delivery, :result],
        [:ash_hooks, :delivery, :backoff],
        [:ash_hooks, :delivery, :dead_letter],
        [:ash_hooks, :delivery, :disable]
      ],
      fn event, measurements, metadata, _ ->
        send(parent, {:event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  def secret, do: {:ok, @ingress_secret}

  defp events do
    receive do
      {:event, name, m, md} -> [{name, m, md} | events()]
    after
      50 -> []
    end
  end

  defp endpoint!,
    do:
      Ash.create!(Endpoint, %{url: "https://hooks.example.test/accept", secret_ref: "acme"},
        authorize?: false
      )

  defp row!(endpoint) do
    Ash.create!(
      Delivery,
      %{
        event_uuid: "msg_tel_#{System.unique_integer([:positive])}",
        event_type: "order_paid",
        payload: ~s({"tel" => 1}),
        endpoint_id: endpoint.id
      },
      action: :dispatch,
      authorize?: false
    )
  end

  defp config(overrides \\ []) do
    [
      deliveries: Delivery,
      endpoints: Endpoint,
      secret_resolver: fn "acme" -> {:ok, @secret} end,
      http: HttpDouble,
      max_attempts: 2,
      base_backoff_seconds: 2,
      max_backoff_seconds: 3600,
      retry_after_cap_seconds: 86_400,
      ssrf_check: &AshHooks.Ssrf.registration_safe?/1,
      now: fn -> DateTime.utc_now() |> DateTime.truncate(:second) end
    ]
    |> Keyword.merge(overrides)
  end

  describe "delivery events" do
    test "a succeeded attempt emits attempt + result with the status, nothing else" do
      ep = endpoint!()
      row = row!(ep)

      assert :ok =
               DeliveryRuntime.run(
                 %{"endpoint_id" => row.endpoint_id, "event_uuid" => row.event_uuid},
                 config()
               )

      received = events()
      {attempt_md, _} = find(received, [:ash_hooks, :delivery, :attempt])
      {result_md, _} = find(received, [:ash_hooks, :delivery, :result])

      assert attempt_md == %{endpoint_id: ep.id, event_uuid: row.event_uuid, attempts: 1}
      assert result_md.status == :succeeded
      assert result_md.response_status == 200
      assert result_md.reason == nil
      # exactly one attempt and one result — nothing else on this path
      assert length(filter(received, [:ash_hooks, :delivery, :attempt])) == 1
      assert length(filter(received, [:ash_hooks, :delivery, :result])) == 1
      assert length(received) == 2
    end

    test "a retryable 5xx emits result + backoff with the classified reason" do
      HttpDouble.set_responses([{:ok, %{status: 502, headers: [], body: "oops"}}])
      ep = endpoint!()
      row = row!(ep)

      assert {:snooze, _} =
               DeliveryRuntime.run(
                 %{"endpoint_id" => row.endpoint_id, "event_uuid" => row.event_uuid},
                 config()
               )

      received = events()
      {result_md, _} = find(received, [:ash_hooks, :delivery, :result])
      {backoff_md, _} = find(received, [:ash_hooks, :delivery, :backoff])

      assert result_md.status == :failed_retryable
      assert result_md.response_status == 502
      assert result_md.reason == "http_502"
      assert backoff_md.delay_seconds >= 4
      assert backoff_md.attempts == 1
    end

    test "a 410 emits disable + dead_letter + result" do
      HttpDouble.set_responses([{:ok, %{status: 410, headers: [], body: "Gone"}}])
      ep = endpoint!()
      row = row!(ep)

      assert :ok =
               DeliveryRuntime.run(
                 %{"endpoint_id" => row.endpoint_id, "event_uuid" => row.event_uuid},
                 config()
               )

      received = events()
      {disable_md, _} = find(received, [:ash_hooks, :delivery, :disable])
      {dead_md, _} = find(received, [:ash_hooks, :delivery, :dead_letter])
      {result_md, _} = find(received, [:ash_hooks, :delivery, :result])

      assert disable_md == %{endpoint_id: ep.id, reason: :gone_410}
      assert dead_md.reason == "gone_410"
      assert dead_md.response_status == 410
      assert result_md.status == :dead_letter
    end

    test "NO event value carries secret material (the ADR-0005 telemetry floor)" do
      # a resolver error leaking the secret through its error term — the
      # classify-without-contents floor must reduce it to a fixed class
      leak = "vault down, secret was " <> @secret

      HttpDouble.set_responses([{:ok, %{status: 502, headers: [], body: "oops"}}])
      ep = endpoint!()
      row = row!(ep)

      assert {:snooze, _} =
               DeliveryRuntime.run(
                 %{"endpoint_id" => row.endpoint_id, "event_uuid" => row.event_uuid},
                 config(secret_resolver: fn _ref -> {:error, leak} end)
               )

      received = events()

      for {_name, measurements, metadata} <- received do
        assert_flat_safe(measurements)
        assert_flat_safe(metadata)
      end

      # the ledger last_error is the classified class, never the leak
      final = Ash.get!(Delivery, row.id, authorize?: false)
      assert final.last_error == "secret_resolution"
      refute final.last_error =~ "whsec"
    end
  end

  describe "ingress events" do
    test "ingest emits verify(:ok) + dedup(:created); a replay adds dedup(:duplicate)" do
      raw = Jason.encode!(%{"id" => "evt_tel_1", "type" => "counted", "n" => 1})

      assert {:ok, :created, _} = Ingress.ingest(Ledger, :counter, raw, ingress_ctx(raw))
      assert {:ok, :duplicate, _} = Ingress.ingest(Ledger, :counter, raw, ingress_ctx(raw))

      received = events()

      {verify_md, verify_m} = find(received, [:ash_hooks, :ingress, :verify])
      assert verify_md.outcome == :ok
      assert verify_md.source == :counter
      # milliseconds, not native units (cross-vendor fix): a healthy
      # verify is well under seconds
      assert verify_m.duration_ms < 5_000

      outcomes =
        received
        |> filter([:ash_hooks, :ingress, :dedup])
        |> Enum.map(& &1.outcome)

      assert outcomes == [:created, :duplicate]
    end

    test "claim emits :claimed then :lease_held on a live foreign lease" do
      # a failing handler leaves the row re-driveable (:failed_retryable),
      # so the lease machine is observable directly
      raw = Jason.encode!(%{"id" => "evt_tel_3", "type" => "counted", "n" => 1})
      assert {:ok, :created, delivery} = Ingress.ingest(Ledger, :counter, raw, ingress_ctx(raw))

      # strand the row back in :received — the claimable state
      Repo.query!("UPDATE #{@ledgers} SET status = 'received' WHERE id = ?", [delivery.id])

      assert {:ok, _token, _} = Ingress.claim_delivery(Ledger, delivery.id)
      {:error, :lease_held} = Ingress.claim_delivery(Ledger, delivery.id)

      outcomes =
        events()
        |> filter([:ash_hooks, :ingress, :claim])
        |> Enum.map(& &1.outcome)

      # ingest's own drive claimed first; the observable pair is ours
      assert Enum.take(outcomes, -2) == [:claimed, :lease_held]
    end

    test "a tampered signature emits verify(:invalid) with the fixed class atom" do
      raw = Jason.encode!(%{"id" => "evt_tel_2", "type" => "counted", "n" => 1})
      ctx = Map.put(ingress_ctx(raw), :signature, flip_first(sign(raw)))

      assert {:error, _} = Ingress.ingest(Ledger, :counter, raw, ctx)

      {verify_md, _} = find(events(), [:ash_hooks, :ingress, :verify])
      assert verify_md.outcome == :invalid

      assert verify_md.reason in [
               :invalid_signature,
               :malformed_payload,
               :stale_timestamp,
               :unknown_event_type
             ]
    end
  end

  describe "the fingerprint helper" do
    test "fingerprint/1 is a stable 8-hex non-reversible identity" do
      fp = AshHooks.Telemetry.fingerprint(@secret)
      assert Regex.match?(~r/^[0-9a-f]{8}$/, fp)
      assert fp == AshHooks.Telemetry.fingerprint(@secret)
      assert fp != AshHooks.Telemetry.fingerprint(@secret <> "x")
      refute fp =~ @secret
    end
  end

  # event helpers

  defp find(received, name) do
    case Enum.find(received, fn {n, _, _} -> n == name end) do
      {_n, m, md} -> {md, m}
      nil -> flunk("no #{inspect(name)} event fired")
    end
  end

  defp filter(received, name),
    do:
      received |> Enum.filter(fn {n, _, _} -> n == name end) |> Enum.map(fn {_, _, md} -> md end)

  defp assert_flat_safe(map) do
    map
    |> Map.values()
    |> Enum.each(fn value ->
      assert is_atom(value) or is_integer(value) or is_binary(value) or is_nil(value) or
               is_float(value)

      if is_binary(value), do: refute(value =~ "whsec")
    end)
  end

  defp ingress_ctx(body) do
    %{
      signature: sign(body),
      headers: %{},
      scope: %{"account_id" => "acct-tel"}
    }
  end

  defp sign(body),
    do: :crypto.mac(:hmac, :sha256, @ingress_secret, body) |> Base.encode16(case: :lower)

  # flip the FIRST char to a different char (the tamper trap: a constant
  # replace can no-op)
  defp flip_first(<<first, rest::binary>>) when first == ?f, do: <<?0, rest::binary>>
  defp flip_first(<<_first, rest::binary>>), do: <<?f, rest::binary>>
end
