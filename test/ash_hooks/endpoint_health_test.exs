defmodule AshHooks.EndpointHealthTest do
  @moduledoc """
  Endpoint health: per-endpoint success rate and latency percentiles over
  a window, computed from the attempt history; and the sustained-failure
  auto-disable policy — a configurable duration and failure share beside
  the existing 410 rule — with telemetry BEFORE and WHEN it disables.
  Re-enabling stays an explicit application action.
  """

  defmodule Endpoint do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.EndpointHealthTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Endpoint]

    sqlite do
      table("health_endpoints")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read, :create, :update])
      default_accept(:*)
    end

    endpoint do
      auto_disable do
        failure_window_seconds(3_600)
        failure_share(0.5)
        min_attempts(4)
        warning_min_attempts(2)
      end
    end
  end

  defmodule PlainEndpoint do
    @moduledoc false
    # no auto_disable policy: the sweep never considers it
    use Ash.Resource,
      domain: AshHooks.EndpointHealthTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Endpoint]

    sqlite do
      table("health_plain_endpoints")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read, :create, :update])
      default_accept(:*)
    end
  end

  defmodule Attempt do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.EndpointHealthTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundAttempt]

    sqlite do
      table("health_attempts")
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
      resource(AshHooks.EndpointHealthTest.Endpoint)
      resource(AshHooks.EndpointHealthTest.PlainEndpoint)
      resource(AshHooks.EndpointHealthTest.Attempt)
    end
  end

  use ExUnit.Case, async: false

  require Ash.Query

  alias AshHooks.Test.Repo

  @endpoints "health_endpoints"
  @plain "health_plain_endpoints"
  @attempts "health_attempts"

  setup_all do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@endpoints} (
      id TEXT PRIMARY KEY, url TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'enabled',
      secret_ref TEXT NOT NULL, previous_secret_ref TEXT, legacy_secret_ref TEXT,
      legacy_previous_secret_ref TEXT, disable_warned_at TEXT
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@plain} (
      id TEXT PRIMARY KEY, url TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'enabled',
      secret_ref TEXT NOT NULL, previous_secret_ref TEXT, legacy_secret_ref TEXT,
      legacy_previous_secret_ref TEXT
    )
    """)

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

    on_exit(fn ->
      Repo.query!("DROP TABLE IF EXISTS #{@attempts}")
      Repo.query!("DROP TABLE IF EXISTS #{@endpoints}")
      Repo.query!("DROP TABLE IF EXISTS #{@plain}")
    end)

    :ok
  end

  setup do
    Repo.query!("DELETE FROM #{@attempts}")
    Repo.query!("DELETE FROM #{@endpoints}")
    Repo.query!("DELETE FROM #{@plain}")

    test_pid = self()

    :telemetry.attach_many(
      "health-test",
      [
        [:ash_hooks, :endpoint, :disable_warning],
        [:ash_hooks, :endpoint, :disable]
      ],
      fn event, _m, metadata, _c -> send(test_pid, {event, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("health-test") end)
    :ok
  end

  defp endpoint!(table \\ @endpoints) do
    id = Ash.UUID.generate()

    Repo.query!(
      "INSERT INTO #{table} (id, url, status, secret_ref) VALUES (?, 'https://hooks.example.test/hook', 'enabled', 'health-main')",
      [id]
    )

    # return the resource struct for whichever table
    module = if table == @endpoints, do: Endpoint, else: PlainEndpoint
    Ash.get!(module, id, authorize?: false)
  end

  defp seed_attempt!(endpoint_id, n, outcome, latency_ms) do
    Repo.query!(
      """
      INSERT INTO #{@attempts}
        (id, delivery_pk, endpoint_id, event_uuid, event_type, attempt, outcome,
         response_status, latency_ms, attempted_at)
      VALUES (?, ?, ?, ?, 'order_paid', ?, ?, ?, ?, datetime('now'))
      """,
      [
        Ash.UUID.generate(),
        Jason.encode!(%{"id" => Ash.UUID.generate()}),
        endpoint_id,
        "msg_health_#{n}",
        1,
        Atom.to_string(outcome),
        if(outcome == :succeeded, do: 200, else: nil),
        latency_ms
      ]
    )
  end

  test "stats computes success rate and latency percentiles over a window" do
    endpoint = endpoint!()

    # 3 succeeded of 4 attempts; latencies 10,20,30,300 on the sends
    seed_attempt!(endpoint.id, 1, :succeeded, 10)
    seed_attempt!(endpoint.id, 2, :succeeded, 20)
    seed_attempt!(endpoint.id, 3, :dead_letter, 300)
    seed_attempt!(endpoint.id, 4, :succeeded, 30)

    assert {:ok, stats} =
             AshHooks.EndpointHealth.stats(Attempt,
               endpoint_id: endpoint.id,
               window_seconds: 3_600
             )

    assert stats.attempts == 4
    assert stats.succeeded == 3
    assert_in_delta stats.success_rate, 0.75, 1.0e-9
    # every seed is attempt 1 with a distinct delivery_pk: all three
    # successes are FIRST-attempt successes, and eventual == the same
    # three (no retries in this window)
    assert stats.first_attempt_successes == 3
    assert stats.eventual_successes == 3
    assert stats.deliveries == 4
    # nearest-rank percentiles over [10, 20, 30, 300]
    assert stats.latency_p50_ms == 20
    assert stats.latency_p90_ms == 300
    assert stats.latency_p99_ms == 300
  end

  test "an empty window reports zeros, not errors" do
    endpoint = endpoint!()

    assert {:ok, stats} = AshHooks.EndpointHealth.stats(Attempt, endpoint_id: endpoint.id)

    assert stats.attempts == 0
    assert stats.success_rate == nil
    assert stats.latency_p50_ms == nil
  end

  test "a disable always follows an EARLIER warning sweep — never the first observation" do
    failing = endpoint!()
    thin = endpoint!()
    healthy = endpoint!()

    # failing: 4/4 dead — meets share AND min_attempts on the FIRST sweep
    for n <- 1..4, do: seed_attempt!(failing.id, "f#{n}", :dead_letter, 100)

    # thin evidence: 2/2 dead — meets share and WARNING threshold only
    seed_attempt!(thin.id, "t1", :dead_letter, 100)
    seed_attempt!(thin.id, "t2", :dead_letter, 100)

    # healthy: all succeeded
    for n <- 1..5, do: seed_attempt!(healthy.id, "h#{n}", :succeeded, 40)

    # Sweep 1: NOBODY disables — the failing endpoint WARNED (durably),
    # the thin endpoint warned, the healthy one untouched
    assert {:ok, %{disabled: 0, warned: 2}} =
             AshHooks.EndpointHealth.sweep(Endpoint, Attempt)

    assert Ash.get!(Endpoint, failing.id, authorize?: false).status == :enabled
    assert Ash.get!(Endpoint, failing.id, authorize?: false).disable_warned_at != nil

    refute_received {[:ash_hooks, :endpoint, :disable], _}

    assert_receive {[:ash_hooks, :endpoint, :disable_warning],
                    %{endpoint_id: failing_id, failure_share: failing_share}}

    assert failing_id == failing.id
    assert_in_delta failing_share, 1.0, 1.0e-9

    assert_receive {[:ash_hooks, :endpoint, :disable_warning], %{endpoint_id: thin_id}}

    assert thin_id == thin.id

    # Sweep 2: the failure held — NOW the breaker opens, and the warned
    # stamp clears with it
    assert {:ok, %{disabled: 1, warned: 1}} =
             AshHooks.EndpointHealth.sweep(Endpoint, Attempt)

    disabled = Ash.get!(Endpoint, failing.id, authorize?: false)
    assert disabled.status == :disabled
    assert disabled.disable_warned_at == nil
    assert Ash.get!(Endpoint, thin.id, authorize?: false).status == :enabled
    assert Ash.get!(Endpoint, healthy.id, authorize?: false).status == :enabled

    assert_receive {[:ash_hooks, :endpoint, :disable],
                    %{endpoint_id: id, reason: :sustained_failure}}

    assert id == failing.id
  end

  test "recovery below the warning band clears the warned stamp — a later degradation warns again" do
    flaky = endpoint!()

    for n <- 1..4, do: seed_attempt!(flaky.id, "r#{n}", :dead_letter, 100)

    # degrade: warned on the first sweep
    assert {:ok, %{disabled: 0, warned: 1}} =
             AshHooks.EndpointHealth.sweep(Endpoint, Attempt)

    assert Ash.get!(Endpoint, flaky.id, authorize?: false).disable_warned_at != nil

    # recover: the window empties — the stamp clears (a healthy endpoint
    # carries no standing warning)
    Repo.query!("DELETE FROM #{@attempts}")

    assert {:ok, %{disabled: 0, warned: 0}} =
             AshHooks.EndpointHealth.sweep(Endpoint, Attempt)

    assert Ash.get!(Endpoint, flaky.id, authorize?: false).disable_warned_at == nil

    # degrade again: a FRESH warning cycle — sweep warns, the next disables
    for n <- 1..4, do: seed_attempt!(flaky.id, "d#{n}", :dead_letter, 100)

    assert {:ok, %{disabled: 0, warned: 1}} =
             AshHooks.EndpointHealth.sweep(Endpoint, Attempt)

    assert Ash.get!(Endpoint, flaky.id, authorize?: false).status == :enabled

    assert {:ok, %{disabled: 1, warned: 0}} =
             AshHooks.EndpointHealth.sweep(Endpoint, Attempt)

    assert Ash.get!(Endpoint, flaky.id, authorize?: false).status == :disabled
  end

  test "the auto_disable DSL rejects out-of-band shares" do
    source = """
    defmodule AshHooks.BadShareEndpoint do
      use Ash.Resource,
        domain: AshHooks.EndpointHealthTest.Domain,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshHooks.Endpoint]

      endpoint do
        auto_disable do
          failure_share(1.5)
        end
      end
    end
    """

    assert_raise Spark.Error.DslError, ~r/must be a number in \(0, 1\]/, fn ->
      Code.compile_string(source)
    end
  after
    _ = :code.purge(AshHooks.BadShareEndpoint)
    _ = :code.delete(AshHooks.BadShareEndpoint)
  end

  test "the warning thresholds default from the disable thresholds" do
    # warning_share defaults to failure_share; warning_min_attempts to
    # half of min_attempts (at least 1) — asserted through the resolved
    # policy of the test's own Endpoint (share 0.5, min 4 → warn at 2)
    policy = AshHooks.Endpoint.auto_disable_policy(Endpoint)

    assert policy.warning_share == policy.failure_share
    assert policy.warning_min_attempts == 2
    assert policy.failure_window_seconds == 3_600

    # a defaults-only declaration resolves the documented defaults
    source = """
    defmodule AshHooks.DefaultPolicyEndpoint do
      use Ash.Resource,
        domain: AshHooks.EndpointHealthTest.Domain,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshHooks.Endpoint]

      endpoint do
        auto_disable do
        end
      end
    end
    """

    modules = Code.compile_string(source)

    assert {AshHooks.DefaultPolicyEndpoint, _beam} =
             List.keyfind(modules, AshHooks.DefaultPolicyEndpoint, 0)

    default = AshHooks.Endpoint.auto_disable_policy(AshHooks.DefaultPolicyEndpoint)

    assert default.failure_window_seconds == 3_600
    assert default.failure_share == 0.95
    assert default.min_attempts == 10
    assert default.warning_share == 0.95
    assert default.warning_min_attempts == 5
  after
    _ = :code.purge(AshHooks.DefaultPolicyEndpoint)
    _ = :code.delete(AshHooks.DefaultPolicyEndpoint)
  end

  test "error arms: bad stats args, storage faults, and plain reads" do
    endpoint = endpoint!()

    # the no-opts call names the argument error (the \\ [] arm)
    assert {:error, %AshHooks.Errors.Unknown.UnknownError{error: error}} =
             AshHooks.EndpointHealth.stats(Attempt)

    assert error =~ ":endpoint_id"

    # a history read failure never stops the sweep (counted as considered,
    # neither disabled nor warned)
    Repo.query!("DROP TABLE IF EXISTS #{@attempts}")

    assert {:ok, %{disabled: 0, warned: 0}} =
             AshHooks.EndpointHealth.sweep(Endpoint, Attempt, now: DateTime.utc_now())

    # and stats surfaces the read error
    assert {:error, %Ash.Error.Unknown{}} =
             AshHooks.EndpointHealth.stats(Attempt, endpoint_id: endpoint.id)

    # the endpoints read itself failing is an error
    recreate_attempts!()

    Repo.query!("DROP TABLE #{@endpoints}")

    assert {:error, %Ash.Error.Unknown{}} =
             AshHooks.EndpointHealth.sweep(Endpoint, Attempt, now: DateTime.utc_now())

    recreate_endpoints!()
  end

  test "the sweep re-runs cleanly and skips policy-less resources" do
    # a plain endpoint with failing attempts is never considered
    plain = endpoint!(@plain)
    for n <- 1..6, do: seed_attempt!(plain.id, "p#{n}", :dead_letter, 10)

    assert {:ok, %{disabled: 0, warned: 0}} =
             AshHooks.EndpointHealth.sweep(PlainEndpoint, Attempt)

    assert Ash.get!(PlainEndpoint, plain.id, authorize?: false).status == :enabled

    # warn sweep, disable sweep, then nothing more — a disabled endpoint
    # is out of the sweep's consideration set
    failing = endpoint!()
    for n <- 1..4, do: seed_attempt!(failing.id, "s#{n}", :dead_letter, 10)

    assert {:ok, %{disabled: 0, warned: 1}} = AshHooks.EndpointHealth.sweep(Endpoint, Attempt)
    assert {:ok, %{disabled: 1, warned: 0}} = AshHooks.EndpointHealth.sweep(Endpoint, Attempt)
    assert {:ok, %{disabled: 0, warned: 0}} = AshHooks.EndpointHealth.sweep(Endpoint, Attempt)
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

  defp recreate_endpoints! do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@endpoints} (
      id TEXT PRIMARY KEY, url TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'enabled',
      secret_ref TEXT NOT NULL, previous_secret_ref TEXT, legacy_secret_ref TEXT,
      legacy_previous_secret_ref TEXT, disable_warned_at TEXT
    )
    """)
  end
end
