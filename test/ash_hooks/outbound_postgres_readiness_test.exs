if Code.ensure_loaded?(Oban) do
  defmodule AshHooks.OutboundPostgresReadinessTest do
    @moduledoc """
    PostgreSQL/Oban.Basic qualification for outbound ownership and recovery.

    Every transport assertion reads the designated webhook-tester session's
    append-only request log. Mutable delivery rows are never used as a proxy for
    the number of receiver-visible sends.
    """

    require Ash.Query

    defmodule Endpoint do
      @moduledoc false
      use Ash.Resource,
        domain: AshHooks.OutboundPostgresReadinessTest.Domain,
        data_layer: AshPostgres.DataLayer,
        extensions: [AshHooks.Endpoint]

      postgres do
        table("outbound_readiness_endpoints")
        repo(AshHooks.TestPostgres.Repo)
      end

      attributes do
        uuid_v7_primary_key(:id)
      end

      actions do
        defaults([:read, :create, :update])
        default_accept(:*)
      end
    end

    defmodule Subscription do
      @moduledoc false
      use Ash.Resource,
        domain: AshHooks.OutboundPostgresReadinessTest.Domain,
        data_layer: AshPostgres.DataLayer,
        extensions: [AshHooks.Subscription]

      postgres do
        table("outbound_readiness_subscriptions")
        repo(AshHooks.TestPostgres.Repo)
      end

      attributes do
        uuid_v7_primary_key(:id)
      end

      actions do
        defaults([:create])
        default_accept(:*)

        read :read do
          primary?(true)

          pagination do
            required?(true)
            offset?(true)
            default_limit(2)
          end
        end
      end

      subscription do
        endpoint_resource(AshHooks.OutboundPostgresReadinessTest.Endpoint)
      end
    end

    defmodule Delivery do
      @moduledoc false
      use Ash.Resource,
        domain: AshHooks.OutboundPostgresReadinessTest.Domain,
        data_layer: AshPostgres.DataLayer,
        extensions: [AshHooks.OutboundDelivery]

      postgres do
        table("outbound_readiness_deliveries")
        repo(AshHooks.TestPostgres.Repo)
      end

      attributes do
        uuid_v7_primary_key(:id)
        timestamps()
      end

      actions do
        defaults([:read])
      end
    end

    defmodule Emitter do
      @moduledoc false
      use Ash.Resource,
        domain: AshHooks.OutboundPostgresReadinessTest.Domain,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshHooks]

      webhooks do
        outbound :order_paid do
          subscriptions(AshHooks.OutboundPostgresReadinessTest.Subscription)
          deliveries(AshHooks.OutboundPostgresReadinessTest.Delivery)
        end
      end
    end

    defmodule OtherEmitter do
      @moduledoc false
      use Ash.Resource,
        domain: AshHooks.OutboundPostgresReadinessTest.Domain,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshHooks]

      webhooks do
        outbound :order_paid do
          subscriptions(AshHooks.OutboundPostgresReadinessTest.Subscription)
          deliveries(AshHooks.OutboundPostgresReadinessTest.Delivery)
        end
      end
    end

    defmodule Domain do
      @moduledoc false
      use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

      resources do
        resource(AshHooks.OutboundPostgresReadinessTest.Endpoint)
        resource(AshHooks.OutboundPostgresReadinessTest.Subscription)
        resource(AshHooks.OutboundPostgresReadinessTest.Delivery)
        resource(AshHooks.OutboundPostgresReadinessTest.Emitter)
        resource(AshHooks.OutboundPostgresReadinessTest.OtherEmitter)
      end
    end

    defmodule Runtime do
      @moduledoc false

      def secret(_reference),
        do: {:ok, Application.fetch_env!(:ash_hooks, :outbound_readiness_secret)}

      def local_receiver?(url), do: URI.parse(url).host == "127.0.0.1"
    end

    defmodule OtherWorker do
      @moduledoc false
      use AshHooks.Worker,
        deliveries: AshHooks.OutboundPostgresReadinessTest.Delivery,
        endpoints: AshHooks.OutboundPostgresReadinessTest.Endpoint,
        secret_resolver: {AshHooks.OutboundPostgresReadinessTest.Runtime, :secret},
        oban: AshHooks.OutboundPostgresReadinessTest.Oban,
        queue: :outbound_readiness
    end

    defmodule AnonymousWorker do
      @moduledoc false
      use Oban.Worker, queue: :outbound_readiness

      alias AshHooks.Delivery, as: DeliveryRuntime

      alias AshHooks.OutboundPostgresReadinessTest.{
        Delivery,
        Endpoint,
        Runtime
      }

      @oban AshHooks.OutboundPostgresReadinessTest.Oban
      @runnable_states ["available", "scheduled", "executing", "retryable"]

      @impl Oban.Worker
      def perform(%Oban.Job{args: args}) do
        DeliveryRuntime.run(args,
          deliveries: Delivery,
          endpoints: Endpoint,
          secret_resolver: {Runtime, :secret},
          http_opts: [validate_destination: false, timeout: 5_000],
          ssrf_check: &Runtime.local_receiver?/1,
          dispatch_route: args["dispatch_route"],
          attempt_timeout: 3_000,
          finalization_allowance: 1_000,
          max_attempts: 3,
          base_backoff_seconds: 1,
          max_backoff_seconds: 2,
          retry_after_cap_seconds: 60
        )
      end

      def enqueue(delivery, _event) do
        args = %{
          "delivery_pk" => AshHooks.PrimaryKey.encode(delivery),
          "delivery_resource" => Atom.to_string(delivery.__struct__),
          "endpoint_resource" => Atom.to_string(AshHooks.OutboundPostgresReadinessTest.Endpoint),
          "endpoint_id" => to_string(delivery.endpoint_id),
          "event_uuid" => delivery.event_uuid,
          "dispatch_source" => delivery.dispatch_source,
          "dispatch_route" => delivery.dispatch_route
        }

        changeset =
          new(args,
            unique: [
              fields: [:args],
              keys: [
                :delivery_pk,
                :delivery_resource,
                :endpoint_resource,
                :endpoint_id,
                :event_uuid,
                :dispatch_source,
                :dispatch_route
              ],
              period: :infinity,
              states: [:available, :scheduled, :executing, :retryable]
            ]
          )

        case Oban.insert(@oban, changeset) do
          {:ok, %Oban.Job{id: id, state: state, args: persisted}}
          when is_integer(id) and state in @runnable_states ->
            if Map.take(persisted, Map.keys(args)) == args,
              do: :ok,
              else: {:error, :job_identity_mismatch}

          {:ok, %Oban.Job{id: nil}} ->
            {:error, :job_not_persisted}

          {:ok, %Oban.Job{}} ->
            {:error, :job_not_runnable}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end

    defmodule ObanMigration do
      @moduledoc false
      use Ecto.Migration

      def change do
        Oban.Migrations.up(prefix: "outbound_readiness_oban")
      end
    end

    use ExUnit.Case, async: false

    alias AshHooks.Delivery, as: DeliveryRuntime
    alias AshHooks.{Dispatcher, Event, OutboundBinding, PrimaryKey}
    alias AshHooks.Http.Bounded
    alias AshHooks.OutboundPostgresReadinessTest.Worker
    alias AshHooks.TestPostgres.Repo

    @moduletag :postgres
    @oban_schema "outbound_readiness_oban"
    @receiver_port String.to_integer(System.get_env("ASH_HOOKS_REAL_RECEIVER_PORT", "52871"))
    @receiver_root "http://127.0.0.1:#{@receiver_port}"
    @secret AshHooks.Signing.generate_secret()
    @payload Jason.encode!(%{"qualification" => "outbound", "version" => 2})

    setup_all do
      Application.put_env(:ash_hooks, :outbound_readiness_secret, @secret)
      create_resource_tables!()

      on_exit(fn ->
        Repo.query!("DROP TABLE IF EXISTS outbound_readiness_deliveries")
        Repo.query!("DROP TABLE IF EXISTS outbound_readiness_subscriptions")
        Repo.query!("DROP TABLE IF EXISTS outbound_readiness_endpoints")
        Repo.query!("DROP SCHEMA IF EXISTS #{@oban_schema} CASCADE")
        Application.delete_env(:ash_hooks, :outbound_readiness_secret)
      end)

      Repo.query!("CREATE SCHEMA IF NOT EXISTS #{@oban_schema}")

      assert Ecto.Migrator.up(Repo, 2_026_100_601, ObanMigration,
               prefix: @oban_schema,
               log: false
             ) in [:ok, :already_up]

      start_supervised!(
        {Oban,
         engine: Oban.Engines.Basic,
         repo: Repo,
         prefix: @oban_schema,
         queues: false,
         plugins: [],
         name: AshHooks.OutboundPostgresReadinessTest.Oban,
         testing: :disabled}
      )

      :ok
    end

    setup do
      Repo.query!("DELETE FROM outbound_readiness_deliveries")
      Repo.query!("DELETE FROM outbound_readiness_subscriptions")
      Repo.query!("DELETE FROM outbound_readiness_endpoints")
      Repo.query!("DELETE FROM #{@oban_schema}.oban_jobs")
      :ok
    end

    describe "direct driver retry defaults" do
      @tag :driver_defaults
      test "the default ten-attempt ceiling terminalizes without another request" do
        session = receiver_session!()
        endpoint_and_subscription!(session)
        event = event!()
        row = dispatched_row!(event)

        Repo.query!(
          "UPDATE outbound_readiness_deliveries SET attempts = 10 WHERE event_uuid = $1",
          [event.id]
        )

        assert :ok = DeliveryRuntime.run(delivery_args(row), default_delivery_config())
        assert delivery!(event.id).status == :dead_letter
        assert delivery!(event.id).attempts == 10
        assert receiver_count(session, event.id) == 0
      end

      @tag :driver_defaults
      test "a real receiver's Retry-After is capped at the default one day" do
        session = receiver_session!(status: 429, headers: %{"Retry-After" => "172800"})
        endpoint_and_subscription!(session)
        event = event!()
        row = dispatched_row!(event)

        assert {:snooze, 86_400} =
                 DeliveryRuntime.run(delivery_args(row), default_delivery_config())

        final = delivery!(event.id)
        assert final.status == :failed_retryable
        assert final.attempts == 1
        assert final.response_status == 429
        assert DateTime.diff(final.next_attempt_at, DateTime.utc_now(), :second) in 86_390..86_400
        assert_receive_count(session, event.id, 1)
      end

      @tag :driver_defaults
      test "a real 503 uses the default two-second base with jitter" do
        session = receiver_session!(status: 503)
        endpoint_and_subscription!(session)
        event = event!()
        row = dispatched_row!(event)

        assert {:snooze, seconds} =
                 DeliveryRuntime.run(delivery_args(row), default_delivery_config())

        assert seconds in 4..7
        assert delivery!(event.id).status == :failed_retryable
        assert delivery!(event.id).attempts == 1
        assert_receive_count(session, event.id, 1)
      end

      @tag :driver_defaults
      test "the default maximum backoff applies when a caller raises the attempt ceiling" do
        session = receiver_session!(status: 503)
        endpoint_and_subscription!(session)
        event = event!()
        row = dispatched_row!(event)

        Repo.query!(
          "UPDATE outbound_readiness_deliveries SET attempts = 16 WHERE event_uuid = $1",
          [event.id]
        )

        assert {:snooze, 3600} =
                 DeliveryRuntime.run(
                   delivery_args(row),
                   Keyword.put(default_delivery_config(), :max_attempts, 30)
                 )

        assert delivery!(event.id).status == :failed_retryable
        assert delivery!(event.id).attempts == 17
        assert_receive_count(session, event.id, 1)
      end
    end

    describe "explicit nil retry defaults" do
      @tag :driver_nil
      test "the default ten-attempt ceiling terminalizes without another request" do
        session = receiver_session!()
        endpoint_and_subscription!(session)
        event = event!()
        row = dispatched_row!(event)

        Repo.query!(
          "UPDATE outbound_readiness_deliveries SET attempts = 10 WHERE event_uuid = $1",
          [event.id]
        )

        assert :ok = DeliveryRuntime.run(delivery_args(row), nil_retry_config(:max_attempts))
        assert delivery!(event.id).status == :dead_letter
        assert delivery!(event.id).attempts == 10
        assert receiver_count(session, event.id) == 0
      end

      @tag :driver_nil
      test "a real receiver's Retry-After is capped at the default one day" do
        session = receiver_session!(status: 429, headers: %{"Retry-After" => "172800"})
        endpoint_and_subscription!(session)
        event = event!()
        row = dispatched_row!(event)

        assert {:snooze, 86_400} =
                 DeliveryRuntime.run(
                   delivery_args(row),
                   nil_retry_config(:retry_after_cap_seconds)
                 )

        final = delivery!(event.id)
        assert final.status == :failed_retryable
        assert final.attempts == 1
        assert final.response_status == 429
        assert DateTime.diff(final.next_attempt_at, DateTime.utc_now(), :second) in 86_390..86_400
        assert_receive_count(session, event.id, 1)
      end

      @tag :driver_nil
      test "a real 503 uses the default two-second base with jitter" do
        session = receiver_session!(status: 503)
        endpoint_and_subscription!(session)
        event = event!()
        row = dispatched_row!(event)

        assert {:snooze, seconds} =
                 DeliveryRuntime.run(delivery_args(row), nil_retry_config(:base_backoff_seconds))

        assert seconds in 4..7
        assert delivery!(event.id).status == :failed_retryable
        assert delivery!(event.id).attempts == 1
        assert_receive_count(session, event.id, 1)
      end

      @tag :driver_nil
      test "the default maximum backoff applies when a caller raises the attempt ceiling" do
        session = receiver_session!(status: 503)
        endpoint_and_subscription!(session)
        event = event!()
        row = dispatched_row!(event)

        Repo.query!(
          "UPDATE outbound_readiness_deliveries SET attempts = 16 WHERE event_uuid = $1",
          [event.id]
        )

        assert {:snooze, 3600} =
                 DeliveryRuntime.run(
                   delivery_args(row),
                   Keyword.put(nil_retry_config(:max_backoff_seconds), :max_attempts, 30)
                 )

        assert delivery!(event.id).status == :failed_retryable
        assert delivery!(event.id).attempts == 17
        assert_receive_count(session, event.id, 1)
      end
    end

    describe "durable source and route ownership" do
      test "required subscription pagination fans out every PostgreSQL page" do
        session = receiver_session!()

        for _ <- 1..5 do
          endpoint_and_subscription!(session)
        end

        event = event!()
        assert {:ok, results} = Dispatcher.dispatch(Emitter, :order_paid, event)
        assert length(results) == 5
        assert Enum.all?(results, &(&1.status == :deferred))

        assert [[5]] =
                 Repo.query!(
                   "SELECT count(*) FROM outbound_readiness_deliveries WHERE event_uuid = $1",
                   [event.id]
                 ).rows
      end

      test "shared endpoint/event identity refuses another emitter source" do
        {endpoint, _session} = endpoint_and_subscription!()
        event = event!()

        assert {:ok, [%{status: :deferred}]} =
                 Dispatcher.dispatch(Emitter, :order_paid, event)

        assert {:ok, [%{status: :endpoint_error, error: :dispatch_source_conflict}]} =
                 Dispatcher.dispatch(OtherEmitter, :order_paid, event)

        assert [%{endpoint_id: endpoint_id}] = Ash.read!(Delivery, authorize?: false)
        assert endpoint_id == endpoint.id
      end

      test "named route is stable and a different worker route is rejected" do
        {_endpoint, _session} = endpoint_and_subscription!()
        event = event!()

        assert {:ok, [%{status: :created}]} =
                 Dispatcher.dispatch(Emitter, :order_paid, event, enqueue: {Worker, :enqueue})

        assert {:ok, [%{status: :endpoint_error, error: :dispatch_route_conflict}]} =
                 Dispatcher.dispatch(Emitter, :order_paid, event,
                   enqueue: {OtherWorker, :enqueue}
                 )

        assert [[1]] =
                 Repo.query!("SELECT count(*) FROM #{@oban_schema}.oban_jobs").rows
      end

      test "keyed anonymous recovery works and unkeyed anonymous recovery is explicit" do
        {_endpoint, _session} = endpoint_and_subscription!()
        keyed = event!()
        unkeyed = event!()
        enqueue = fn row, event -> AnonymousWorker.enqueue(row, event) end

        assert {:ok, [%{status: :created}]} =
                 Dispatcher.dispatch(Emitter, :order_paid, keyed,
                   enqueue: enqueue,
                   enqueue_key: :stable_route
                 )

        assert {:ok, [%{status: :created}]} =
                 Dispatcher.dispatch(Emitter, :order_paid, unkeyed, enqueue: enqueue)

        assert [[2]] = Repo.query!("SELECT count(*) FROM #{@oban_schema}.oban_jobs").rows

        assert [[keyed_job_id, "available", keyed_args]] = jobs_for_event(keyed.id)
        assert is_integer(keyed_job_id)
        assert keyed_args["event_uuid"] == keyed.id

        assert [[unkeyed_job_id, "available", unkeyed_args]] = jobs_for_event(unkeyed.id)
        assert is_integer(unkeyed_job_id)
        assert unkeyed_args["event_uuid"] == unkeyed.id

        Repo.query!(
          "UPDATE #{@oban_schema}.oban_jobs SET state = 'discarded', discarded_at = now() WHERE id = $1",
          [keyed_job_id]
        )

        age_rows!()

        assert {:ok, results} =
                 Dispatcher.reconcile_pending(Emitter, :order_paid,
                   enqueue: enqueue,
                   enqueue_key: :stable_route,
                   older_than: DateTime.utc_now()
                 )

        assert Enum.any?(results, &(&1.status == :reconciled))
        assert Enum.any?(results, &(&1.error == :unresolved_route))

        assert [
                 [^keyed_job_id, "discarded", first_keyed_args],
                 [recovery_job_id, "available", recovery_args]
               ] = jobs_for_event(keyed.id)

        assert is_integer(recovery_job_id)
        assert recovery_job_id > keyed_job_id
        assert first_keyed_args["event_uuid"] == keyed.id
        assert recovery_args["event_uuid"] == keyed.id

        assert {:ok, unresolved_results} =
                 Dispatcher.reconcile_pending(Emitter, :order_paid,
                   enqueue: enqueue,
                   older_than: DateTime.utc_now()
                 )

        assert Enum.any?(unresolved_results, &(&1.error == :unresolved_route))
        assert [[^unkeyed_job_id, "available", ^unkeyed_args]] = jobs_for_event(unkeyed.id)
      end

      test "deferred route binds once and deleted subscriptions do not prevent recovery" do
        {_endpoint, _session} = endpoint_and_subscription!()
        event = event!()

        assert {:ok, [%{status: :deferred}]} =
                 Dispatcher.dispatch(Emitter, :order_paid, event)

        age_rows!()
        Repo.query!("DELETE FROM outbound_readiness_subscriptions")

        assert {:ok, [%{status: :reconciled}]} =
                 Dispatcher.reconcile_pending(Emitter, :order_paid,
                   enqueue: {Worker, :enqueue},
                   older_than: DateTime.utc_now()
                 )

        assert [%{dispatch_route: route}] = Ash.read!(Delivery, authorize?: false)
        assert route == OutboundBinding.named_route(Worker, :enqueue)

        assert {:ok, [%{status: :enqueue_failed, error: :dispatch_route_conflict}]} =
                 Dispatcher.reconcile_pending(Emitter, :order_paid,
                   enqueue: {OtherWorker, :enqueue},
                   older_than: DateTime.utc_now()
                 )
      end
    end

    describe "PostgreSQL attempt ownership and receiver-visible sends" do
      test "a live send lease prevents direct/queued contention from sending twice" do
        session = receiver_session!(delay: 2)
        {endpoint, _subscription} = endpoint_and_subscription!(session)
        event = event!()

        assert {:ok, [%{status: :created}]} =
                 Dispatcher.dispatch(Emitter, :order_paid, event, enqueue: {Worker, :enqueue})

        args = queued_job_args!()

        first =
          Task.async(fn -> DeliveryRuntime.run(args, delivery_config(attempt_timeout: 5_000)) end)

        assert_receive_count(session, event.id, 1)

        assert {:snooze, _seconds} = Worker.perform(%Oban.Job{args: args})
        assert :ok = Task.await(first, 6_000)
        assert receiver_count(session, event.id) == 1
        assert Ash.get!(Endpoint, endpoint.id, authorize?: false).status == :enabled
      end

      test "a reset attempt counter cannot let an old result cross a newer token fence" do
        delayed = receiver_session!(delay: 2)
        immediate = receiver_session!()
        {endpoint, _subscription} = endpoint_and_subscription!(delayed)
        event = event!()
        row = dispatched_row!(event)
        args = delivery_args(row)

        old =
          Task.async(fn -> DeliveryRuntime.run(args, delivery_config(attempt_timeout: 5_000)) end)

        assert_receive_count(delayed, event.id, 1)

        Repo.query!(
          """
          UPDATE outbound_readiness_deliveries
          SET attempts = 0, send_lease_expires_at = now() - interval '1 second'
          WHERE event_uuid = $1
          """,
          [event.id]
        )

        set_endpoint_url!(endpoint, receiver_url(immediate))
        assert :ok = DeliveryRuntime.run(args, delivery_config())
        assert {:snooze, 1} = Task.await(old, 6_000)

        final = delivery!(event.id)
        assert final.status == :succeeded
        assert receiver_count(delayed, event.id) == 1
        assert receiver_count(immediate, event.id) == 1
      end

      test "a delayed 410 cannot disable a replacement endpoint configuration" do
        gone = receiver_session!(status: 410, delay: 2)
        replacement = receiver_session!()
        {endpoint, _subscription} = endpoint_and_subscription!(gone)
        event = event!()
        row = dispatched_row!(event)

        task =
          Task.async(fn ->
            DeliveryRuntime.run(delivery_args(row), delivery_config(attempt_timeout: 5_000))
          end)

        assert_receive_count(gone, event.id, 1)
        set_endpoint_url!(endpoint, receiver_url(replacement))
        assert :ok = Task.await(task, 6_000)

        assert Ash.get!(Endpoint, endpoint.id, authorize?: false).status == :enabled
        assert delivery!(event.id).status == :dead_letter
        assert receiver_count(gone, event.id) == 1
        assert receiver_count(replacement, event.id) == 0
      end

      test "a 410 snapshot remains recoverable when PostgreSQL rejects its pending write" do
        gone = receiver_session!(status: 410)
        {_endpoint, _subscription} = endpoint_and_subscription!(gone)
        event = event!()
        row = dispatched_row!(event)
        install_disable_pending_rejection!()

        assert {:error, {:reconcile_failed, _reason}} =
                 DeliveryRuntime.run(delivery_args(row), delivery_config())

        assert_receive_count(gone, event.id, 1)
        stranded = delivery!(event.id)
        assert stranded.status == :sending
        assert is_binary(stranded.attempt_token)
        assert %DateTime{} = stranded.send_lease_expires_at
      after
        remove_disable_pending_rejection!()
      end

      test "a stale 410 pending write is fenced without disabling the endpoint" do
        gone = receiver_session!(status: 410)
        {endpoint, _subscription} = endpoint_and_subscription!(gone)
        event = event!()
        row = dispatched_row!(event)

        Repo.query!("""
        CREATE OR REPLACE FUNCTION ignore_disable_pending()
        RETURNS trigger AS $$
        BEGIN
          RETURN NULL;
        END;
        $$ LANGUAGE plpgsql
        """)

        Repo.query!("""
        CREATE TRIGGER ignore_disable_pending
        BEFORE UPDATE ON outbound_readiness_deliveries
        FOR EACH ROW
        WHEN (NEW.status = 'disable_pending')
        EXECUTE FUNCTION ignore_disable_pending()
        """)

        assert {:snooze, 1} = DeliveryRuntime.run(delivery_args(row), delivery_config())
        assert_receive_count(gone, event.id, 1)
        assert delivery!(event.id).status == :sending
        assert Ash.get!(Endpoint, endpoint.id, authorize?: false).status == :enabled
      after
        Repo.query!(
          "DROP TRIGGER IF EXISTS ignore_disable_pending ON outbound_readiness_deliveries"
        )

        Repo.query!("DROP FUNCTION IF EXISTS ignore_disable_pending()")
      end

      test "the total deadline leaves one recoverable retry after a real delayed request" do
        session = receiver_session!(delay: 2)
        {_endpoint, _subscription} = endpoint_and_subscription!(session)
        event = event!()
        row = dispatched_row!(event)

        assert {:snooze, _seconds} =
                 DeliveryRuntime.run(
                   delivery_args(row),
                   # Leave time for real PostgreSQL admission and endpoint reads.
                   # The receiver's two-second delay still exceeds this budget.
                   delivery_config(attempt_timeout: 1_000, finalization_allowance: 1_000)
                 )

        assert_receive_count(session, event.id, 1)
        final = delivery!(event.id)
        assert final.status == :failed_retryable
        assert is_binary(final.attempt_token)
        assert is_nil(final.send_lease_expires_at)
      end

      test "the final-attempt ceiling terminalizes without another receiver send" do
        session = receiver_session!()
        {_endpoint, _subscription} = endpoint_and_subscription!(session)
        event = event!()
        row = dispatched_row!(event)

        Repo.query!(
          """
          UPDATE outbound_readiness_deliveries
          SET status = 'sending', attempts = 3, attempt_token = $1::text::uuid,
              send_lease_expires_at = now() - interval '1 second'
          WHERE event_uuid = $2
          """,
          [Ash.UUID.generate(), event.id]
        )

        assert :ok = DeliveryRuntime.run(delivery_args(row), delivery_config(max_attempts: 3))
        assert delivery!(event.id).status == :dead_letter
        assert receiver_count(session, event.id) == 0
      end

      test "a future Retry-After is excluded from recovery until it is due" do
        session = receiver_session!(status: 429, headers: %{"Retry-After" => "60"})
        {_endpoint, _subscription} = endpoint_and_subscription!(session)
        event = event!()
        row = dispatched_row!(event)

        assert {:snooze, seconds} =
                 DeliveryRuntime.run(
                   delivery_args(row),
                   delivery_config(retry_after_cap_seconds: 60)
                 )

        assert seconds in 1..60
        assert_receive_count(session, event.id, 1)

        assert {:ok, []} =
                 Dispatcher.reconcile_pending(Emitter, :order_paid,
                   enqueue: {Worker, :enqueue},
                   older_than: DateTime.utc_now()
                 )

        assert receiver_count(session, event.id) == 1
      end
    end

    describe "Oban.Basic durable admission and crash recovery" do
      test "concurrent reconcilers persist matching jobs and terminal sends appear once at the receiver" do
        session = receiver_session!()
        endpoint_and_subscription!(session)

        events =
          for index <- 1..5 do
            {:ok, event} =
              Event.new(type: :order_paid, payload: @payload, id: "recovery-batch-#{index}")

            assert {:ok, [%{status: :deferred}]} =
                     Dispatcher.dispatch(Emitter, :order_paid, event)

            event
          end

        age_rows!()

        reconcile = fn ->
          Dispatcher.reconcile_pending(Emitter, :order_paid,
            enqueue: {AnonymousWorker, :enqueue},
            older_than: DateTime.utc_now()
          )
        end

        results =
          for(_ <- 1..6, do: Task.async(reconcile))
          |> Task.await_many(10_000)

        assert Enum.all?(results, &match?({:ok, _}, &1))
        assert {:ok, _} = reconcile.()

        for event <- events do
          assert [[job_id, "available", args]] = jobs_for_event(event.id)
          assert is_integer(job_id)
          assert args["delivery_pk"] == PrimaryKey.encode(delivery!(event.id))

          assert args["dispatch_route"] ==
                   AshHooks.OutboundBinding.named_route(AnonymousWorker, :enqueue)
        end

        assert %{success: 5, failure: 0} =
                 Oban.drain_queue(AshHooks.OutboundPostgresReadinessTest.Oban,
                   queue: :outbound_readiness,
                   with_safety: false
                 )

        assert {:ok, []} = reconcile.()

        for event <- events do
          assert %{status: :succeeded, attempts: 1} = delivery!(event.id)
          assert [[_job_id, "completed", args]] = jobs_for_event(event.id)
          assert :ok = AnonymousWorker.perform(%Oban.Job{args: args})
          assert_receive_count(session, event.id, 1)
        end
      end

      @tag :unsaved_conflict
      test "an unsaved conflict retries until the real winning transaction commits" do
        {_endpoint, _session} = endpoint_and_subscription!()
        event = event!()
        row = dispatched_row!(event)
        route = OutboundBinding.named_route(Worker, :enqueue)
        assert {:ok, bound} = AshHooks.Worker.bind_route(row, route, nil)

        with_uncommitted_job(bound, event, fn holder ->
          observe_admission_jobs(holder)
          assert :ok = Worker.enqueue(bound, event)
          assert_receive {:admission_job, nil, true}
          assert_receive {:admission_job, job_id, true} when is_integer(job_id)
        end)

        assert [[job_id, "available", _args]] = jobs_for_event(event.id)
        assert is_integer(job_id)
      end

      @tag :unsaved_conflict
      test "an unsaved conflict refuses admission after all twenty retries" do
        {_endpoint, _session} = endpoint_and_subscription!()
        event = event!()
        row = dispatched_row!(event)
        route = OutboundBinding.named_route(Worker, :enqueue)
        assert {:ok, bound} = AshHooks.Worker.bind_route(row, route, nil)

        with_uncommitted_job(bound, event, fn _holder ->
          observe_admission_jobs(nil)
          assert {:error, :job_not_persisted} = Worker.enqueue(bound, event)

          for _ <- 1..21, do: assert_receive({:admission_job, nil, true})
          refute_receive {:admission_job, _id, _conflict}, 0
          assert [] = jobs_for_event(event.id)
        end)

        assert [[job_id, "available", _args]] = jobs_for_event(event.id)
        assert is_integer(job_id)
      end

      test "an advisory-lock uniqueness conflict resolves to one persisted job id" do
        {_endpoint, _session} = endpoint_and_subscription!()
        event = event!()
        row = dispatched_row!(event)
        route = OutboundBinding.named_route(Worker, :enqueue)
        assert {:ok, bound} = AshHooks.Worker.bind_route(row, route, nil)
        parent = self()

        tasks =
          for _ <- 1..2 do
            Task.async(fn ->
              send(parent, {:ready, self()})

              receive do
                :go -> Worker.enqueue(bound, event)
              end
            end)
          end

        pids =
          Enum.map(tasks, fn _task ->
            assert_receive {:ready, pid}
            pid
          end)

        Enum.each(pids, &send(&1, :go))
        assert [:ok, :ok] == Enum.map(tasks, &Task.await(&1, 5_000))

        assert [[job_id]] = Repo.query!("SELECT id FROM #{@oban_schema}.oban_jobs").rows
        assert is_integer(job_id)
      end

      test "runnable uniqueness returns the persisted matching job id" do
        {_endpoint, _session} = endpoint_and_subscription!()
        event = event!()
        row = dispatched_row!(event)

        assert :ok = Worker.enqueue(row, event)
        assert :ok = Worker.enqueue(Ash.get!(Delivery, row.id, authorize?: false), event)

        assert [[id, "available", args]] =
                 Repo.query!("""
                 SELECT id, state, args
                 FROM #{@oban_schema}.oban_jobs
                 ORDER BY id
                 """).rows

        assert is_integer(id)
        decoded_args = if is_binary(args), do: Jason.decode!(args), else: args
        assert decoded_args["delivery_pk"] == PrimaryKey.encode(row)
      end

      test "a discarded trigger permits a new persisted job" do
        {_endpoint, _session} = endpoint_and_subscription!()
        event = event!()
        row = dispatched_row!(event)

        assert :ok = Worker.enqueue(row, event)
        [[first_id]] = Repo.query!("SELECT id FROM #{@oban_schema}.oban_jobs").rows

        Repo.query!(
          """
          UPDATE #{@oban_schema}.oban_jobs
          SET state = 'discarded', discarded_at = now()
          WHERE id = $1
          """,
          [first_id]
        )

        assert :ok = Worker.enqueue(Ash.get!(Delivery, row.id, authorize?: false), event)

        assert [[^first_id], [second_id]] =
                 Repo.query!("SELECT id FROM #{@oban_schema}.oban_jobs ORDER BY id").rows

        assert second_id > first_id
      end

      test "a process killed after enqueue claim is reclaimed after its lease expires" do
        {_endpoint, _session} = endpoint_and_subscription!()
        event = event!()
        assert {:ok, [%{status: :deferred}]} = Dispatcher.dispatch(Emitter, :order_paid, event)
        age_rows!()

        install_slow_oban_insert!()

        task =
          Task.async(fn ->
            Dispatcher.reconcile_pending(Emitter, :order_paid,
              enqueue: {Worker, :enqueue},
              older_than: DateTime.utc_now()
            )
          end)

        assert_eventually(fn -> not is_nil(delivery!(event.id).enqueue_token) end)
        Task.shutdown(task, :brutal_kill)
        remove_slow_oban_insert!()

        Repo.query!(
          """
          UPDATE outbound_readiness_deliveries
          SET enqueue_lease_expires_at = now() - interval '1 second'
          WHERE event_uuid = $1
          """,
          [event.id]
        )

        assert {:ok, [%{status: :reconciled}]} =
                 Dispatcher.reconcile_pending(Emitter, :order_paid,
                   enqueue: {Worker, :enqueue},
                   older_than: DateTime.utc_now()
                 )

        assert [[1]] = Repo.query!("SELECT count(*) FROM #{@oban_schema}.oban_jobs").rows
        assert is_nil(delivery!(event.id).enqueue_token)
      after
        remove_slow_oban_insert!()
      end

      test "a persisted recovery job survives a rejected enqueue-lease release" do
        {_endpoint, _session} = endpoint_and_subscription!()
        event = event!()
        assert {:ok, [%{status: :deferred}]} = Dispatcher.dispatch(Emitter, :order_paid, event)
        age_rows!()

        Repo.query!("""
        CREATE OR REPLACE FUNCTION reject_enqueue_release()
        RETURNS trigger AS $$
        BEGIN
          IF OLD.enqueue_token IS NOT NULL AND NEW.enqueue_token IS NULL THEN
            RAISE EXCEPTION 'forced enqueue release rejection';
          END IF;
          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql
        """)

        Repo.query!("""
        CREATE TRIGGER reject_enqueue_release
        BEFORE UPDATE ON outbound_readiness_deliveries
        FOR EACH ROW EXECUTE FUNCTION reject_enqueue_release()
        """)

        assert {:ok, [%{status: :endpoint_error, error: %Ash.Error.Unknown{}}]} =
                 Dispatcher.reconcile_pending(Emitter, :order_paid,
                   enqueue: {Worker, :enqueue},
                   older_than: DateTime.utc_now()
                 )

        assert [[1]] = Repo.query!("SELECT count(*) FROM #{@oban_schema}.oban_jobs").rows
        assert is_binary(delivery!(event.id).enqueue_token)
      after
        Repo.query!(
          "DROP TRIGGER IF EXISTS reject_enqueue_release ON outbound_readiness_deliveries"
        )

        Repo.query!("DROP FUNCTION IF EXISTS reject_enqueue_release()")
      end
    end

    describe "bounded PostgreSQL retention" do
      test "prunes a 1,001-row terminal backlog in bounded batches" do
        {endpoint, _session} = endpoint_and_subscription!()

        Repo.query!(
          """
          INSERT INTO outbound_readiness_deliveries
            (id, event_uuid, event_type, payload, endpoint_id, status, attempts,
             dispatch_source, dispatch_route, inserted_at, updated_at)
          SELECT md5('outbound-retention-' || value)::uuid,
                 'retention-' || value,
                 'order_paid',
                 decode('7b7d', 'hex'),
                 $1::text::uuid,
                 'succeeded',
                 1,
                 'v1:direct:unbound',
                 'v1:route:unbound',
                 now() - interval '30 days',
                 now() - interval '30 days'
          FROM generate_series(1, 1001) AS value
          """,
          [endpoint.id]
        )

        assert {:ok, 1_001} =
                 DeliveryRuntime.prune(Delivery,
                   older_than: DateTime.utc_now(),
                   batch_size: 128
                 )

        assert [[0]] = Repo.query!("SELECT count(*) FROM outbound_readiness_deliveries").rows
      end
    end

    defp create_resource_tables! do
      Repo.query!("""
      CREATE TABLE IF NOT EXISTS outbound_readiness_endpoints (
        id UUID PRIMARY KEY,
        url TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'enabled',
        secret_ref TEXT NOT NULL,
        previous_secret_ref TEXT,
        legacy_secret_ref TEXT,
        legacy_previous_secret_ref TEXT
      )
      """)

      Repo.query!("""
      CREATE TABLE IF NOT EXISTS outbound_readiness_subscriptions (
        id UUID PRIMARY KEY,
        event_types TEXT[] NOT NULL,
        endpoint_id UUID NOT NULL,
        signing_mode TEXT
      )
      """)

      Repo.query!("""
      CREATE TABLE IF NOT EXISTS outbound_readiness_deliveries (
        id UUID PRIMARY KEY,
        event_uuid TEXT NOT NULL,
        event_type TEXT NOT NULL,
        payload BYTEA NOT NULL,
        endpoint_id UUID NOT NULL,
        subscription_id UUID,
        signing_mode TEXT,
        status TEXT NOT NULL DEFAULT 'pending',
        attempts INTEGER NOT NULL DEFAULT 0,
        attempt_token UUID,
        send_lease_expires_at TIMESTAMP,
        enqueue_token UUID,
        enqueue_lease_expires_at TIMESTAMP,
        endpoint_snapshot JSONB,
        response_status INTEGER,
        response_snippet TEXT,
        last_error TEXT,
        next_attempt_at TIMESTAMP,
        dispatch_source TEXT NOT NULL DEFAULT 'v1:direct:unbound',
        dispatch_route TEXT NOT NULL DEFAULT 'v1:route:unbound',
        inserted_at TIMESTAMP NOT NULL,
        updated_at TIMESTAMP NOT NULL
      )
      """)

      Repo.query!("""
      CREATE UNIQUE INDEX IF NOT EXISTS outbound_readiness_delivery_identity
      ON outbound_readiness_deliveries (endpoint_id, event_uuid)
      """)
    end

    defp endpoint_and_subscription!(session \\ receiver_session!()) do
      endpoint =
        Ash.create!(
          Endpoint,
          %{url: "https://hooks.example.test/accept", secret_ref: "outbound-readiness"},
          authorize?: false
        )

      set_endpoint_url!(endpoint, receiver_url(session))

      endpoint = Ash.get!(Endpoint, endpoint.id, authorize?: false)

      subscription =
        Ash.create!(Subscription, %{endpoint_id: endpoint.id}, authorize?: false)

      {endpoint, subscription}
    end

    defp set_endpoint_url!(endpoint, url) do
      Repo.query!("UPDATE outbound_readiness_endpoints SET url = $1 WHERE id = $2::text::uuid", [
        url,
        endpoint.id
      ])

      Ash.get!(Endpoint, endpoint.id, authorize?: false)
    end

    # Hold Oban.Basic's actual uniqueness lock and inserted row in an open
    # PostgreSQL transaction. A second connection must get Oban's unsaved job.
    defp with_uncommitted_job(row, event, fun) do
      parent = self()

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            assert :ok = Worker.enqueue(row, event)
            send(parent, :unique_job_uncommitted)

            receive do
              :commit -> :ok
            after
              5_000 -> raise "uniqueness transaction was not released"
            end
          end)
        end)

      try do
        assert_receive :unique_job_uncommitted, 2_000
        fun.(holder.pid)
      after
        send(holder.pid, :commit)
        assert {:ok, :ok} = Task.await(holder, 5_000)
      end
    end

    defp observe_admission_jobs(commit_on_conflict) do
      handler = {__MODULE__, :admission_jobs, make_ref()}
      parent = self()

      :ok =
        :telemetry.attach(
          handler,
          [:oban, :engine, :insert_job, :stop],
          &__MODULE__.admission_job/4,
          {parent, commit_on_conflict}
        )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    @doc false
    def admission_job(_event, _measurements, %{job: job}, {parent, commit_on_conflict}) do
      if self() == parent do
        id = Map.get(job, :id)
        send(parent, {:admission_job, id, job.conflict?})

        if is_nil(id) and commit_on_conflict do
          send(commit_on_conflict, :commit)
        end
      end
    end

    defp event! do
      {:ok, event} = Event.new(type: :order_paid, payload: @payload)
      event
    end

    defp dispatched_row!(event) do
      assert {:ok, [%{status: :deferred}]} = Dispatcher.dispatch(Emitter, :order_paid, event)
      delivery!(event.id)
    end

    defp delivery!(event_id) do
      Delivery
      |> Ash.Query.filter(event_uuid == ^event_id)
      |> Ash.read_one!(authorize?: false)
    end

    defp delivery_args(row) do
      %{
        "delivery_pk" => PrimaryKey.encode(row),
        "delivery_resource" => Atom.to_string(Delivery),
        "endpoint_resource" => Atom.to_string(Endpoint),
        "endpoint_id" => row.endpoint_id,
        "event_uuid" => row.event_uuid,
        "dispatch_source" => row.dispatch_source,
        "dispatch_route" => row.dispatch_route
      }
    end

    defp queued_job_args! do
      [[args]] =
        Repo.query!("""
        SELECT args
        FROM #{@oban_schema}.oban_jobs
        ORDER BY id DESC
        LIMIT 1
        """).rows

      if is_binary(args), do: Jason.decode!(args), else: args
    end

    defp jobs_for_event(event_id) do
      Repo.query!(
        "SELECT id, state, args FROM #{@oban_schema}.oban_jobs WHERE args->>'event_uuid' = $1 ORDER BY id",
        [event_id]
      ).rows
      |> Enum.map(fn [id, state, args] ->
        [id, state, if(is_binary(args), do: Jason.decode!(args), else: args)]
      end)
    end

    defp delivery_config(overrides \\ []) do
      Keyword.merge(
        [
          deliveries: Delivery,
          endpoints: Endpoint,
          secret_resolver: {Runtime, :secret},
          http_opts: [validate_destination: false, timeout: 5_000],
          ssrf_check: fn url -> URI.parse(url).host == "127.0.0.1" end,
          # Use the driver's normal budgets for real database and receiver work.
          # Deadline tests override them explicitly.
          attempt_timeout: 25_000,
          finalization_allowance: 5_000,
          max_attempts: 3,
          base_backoff_seconds: 1,
          max_backoff_seconds: 2,
          retry_after_cap_seconds: 60
        ],
        overrides
      )
    end

    defp default_delivery_config do
      Keyword.drop(delivery_config(), [
        :max_attempts,
        :base_backoff_seconds,
        :max_backoff_seconds,
        :retry_after_cap_seconds
      ])
    end

    defp nil_retry_config(key) do
      default_delivery_config()
      |> Keyword.merge(
        max_attempts: 10,
        base_backoff_seconds: 2,
        max_backoff_seconds: 3600,
        retry_after_cap_seconds: 86_400
      )
      |> Keyword.put(key, nil)
    end

    defp age_rows! do
      Repo.query!("""
      UPDATE outbound_readiness_deliveries
      SET inserted_at = now() - interval '10 minutes'
      """)
    end

    defp receiver_session!(opts \\ []) do
      body =
        Jason.encode!(%{
          "status_code" => Keyword.get(opts, :status, 200),
          "headers" =>
            opts
            |> Keyword.get(:headers, %{})
            |> Enum.map(fn {name, value} -> %{"name" => name, "value" => value} end),
          "delay" => Keyword.get(opts, :delay, 0),
          "response_body_base64" => Base.encode64(~s({"captured":true}))
        })

      {:ok, %{status: status, body: response}} =
        Bounded.request(
          :post,
          @receiver_root <> "/api/session",
          %{"content-type" => "application/json"},
          body,
          validate_destination: false,
          max_body_bytes: 65_536
        )

      assert status in 200..299
      Jason.decode!(response)["uuid"]
    end

    defp receiver_url(session), do: @receiver_root <> "/" <> session

    defp receiver_count(session, event_id) do
      {:ok, %{status: 200, body: body}} =
        Bounded.request(
          :get,
          @receiver_root <> "/api/session/" <> session <> "/requests",
          %{},
          "",
          validate_destination: false,
          max_body_bytes: 1_048_576
        )

      body
      |> Jason.decode!()
      |> Enum.count(fn request ->
        Enum.any?(request["headers"], fn header ->
          String.downcase(header["name"]) == "webhook-id" and header["value"] == event_id
        end)
      end)
    end

    defp assert_receive_count(session, event_id, expected) do
      assert_eventually(fn -> receiver_count(session, event_id) == expected end)
    end

    defp assert_eventually(fun, attempts \\ 100)

    defp assert_eventually(fun, attempts) when attempts > 0 do
      if fun.() do
        :ok
      else
        Process.sleep(25)
        assert_eventually(fun, attempts - 1)
      end
    end

    defp assert_eventually(_fun, 0), do: flunk("condition did not become true")

    defp install_slow_oban_insert! do
      Repo.query!("""
      CREATE OR REPLACE FUNCTION #{@oban_schema}.slow_outbound_insert()
      RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        PERFORM pg_sleep(10);
        RETURN NEW;
      END;
      $$
      """)

      Repo.query!("""
      CREATE TRIGGER slow_outbound_insert
      BEFORE INSERT ON #{@oban_schema}.oban_jobs
      FOR EACH ROW EXECUTE FUNCTION #{@oban_schema}.slow_outbound_insert()
      """)
    end

    defp remove_slow_oban_insert! do
      Repo.query!("""
      DROP TRIGGER IF EXISTS slow_outbound_insert ON #{@oban_schema}.oban_jobs
      """)
    end

    defp install_disable_pending_rejection! do
      Repo.query!("""
      CREATE OR REPLACE FUNCTION reject_disable_pending()
      RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.status = 'disable_pending' THEN
          RAISE EXCEPTION 'forced disable_pending rejection';
        END IF;
        RETURN NEW;
      END;
      $$
      """)

      Repo.query!("""
      CREATE TRIGGER reject_disable_pending
      BEFORE UPDATE ON outbound_readiness_deliveries
      FOR EACH ROW EXECUTE FUNCTION reject_disable_pending()
      """)
    end

    defp remove_disable_pending_rejection! do
      Repo.query!(
        "DROP TRIGGER IF EXISTS reject_disable_pending ON outbound_readiness_deliveries"
      )

      Repo.query!("DROP FUNCTION IF EXISTS reject_disable_pending()")
    end
  end
end
