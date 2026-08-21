if Code.ensure_loaded?(AshSqlite) do
  defmodule AshHooks.IngressBusyRetryTest do
    @moduledoc """
    Bounded transient-busy retry for the fenced machine's storage ops.

    Own substrate: the main test repo is single-connection (statement-level
    fences), so write contention — and therefore the retry — is unreachable
    there. This fixture uses a throwaway repo with a small pool and a tiny
    busy_timeout; its schema is created under a single-connection repo
    BEFORE the pool opens, so no cold connection can miss the unique index
    (the cross-connection schema-visibility flake root-caused by the
    2026-08-21 probe).
    """

    defmodule Ledger do
      @moduledoc false
      use Ash.Resource,
        domain: AshHooks.IngressBusyRetryTest.Domain,
        data_layer: AshSqlite.DataLayer,
        extensions: [AshHooks, AshHooks.InboundDelivery]

      sqlite do
        table("busy_retry_ledgers")
        repo(AshHooks.Test.BusyRepo)
      end

      inbound_delivery do
        scope_identity([])
      end

      actions do
        defaults([:read])
      end

      webhooks do
        inbound(:mockish) do
          provider(AshHooks.Provider.Mock)
          secret(fn -> {:ok, "busy-secret"} end)
        end
      end
    end

    defmodule Domain do
      @moduledoc false
      use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

      resources do
        resource(AshHooks.IngressBusyRetryTest.Ledger)
      end
    end

    use ExUnit.Case, async: false

    alias AshHooks.Ingress
    alias AshHooks.Test.BusyRepo

    @table "busy_retry_ledgers"
    @secret "busy-secret"
    # pin the type atom — the Mock resolves types via String.to_existing_atom
    _ = :busy_test
    @raw Jason.encode!(%{"type" => "busy_test"})

    setup_all do
      db_path =
        Path.join(System.tmp_dir!(), "ash_hooks_busy_retry_#{System.unique_integer()}.sqlite3")

      # Schema under a SINGLE connection first — every pooled connection
      # that opens afterwards sees the settled schema.
      Application.put_env(:ash_hooks, BusyRepo,
        database: db_path,
        pool_size: 1,
        journal_mode: :wal,
        busy_timeout: 5_000
      )

      {:ok, boot_pid} = BusyRepo.start_link()

      BusyRepo.query!("""
      CREATE TABLE #{@table} (
        id TEXT PRIMARY KEY,
        provider TEXT NOT NULL,
        external_event_id TEXT NOT NULL,
        external_event_type TEXT,
        payload TEXT NOT NULL,
        payload_digest TEXT NOT NULL,
        status TEXT NOT NULL,
        fencing_token INTEGER NOT NULL DEFAULT 0,
        lease_expires_at TEXT,
        error_class TEXT,
        attempts INTEGER NOT NULL DEFAULT 0
      )
      """)

      BusyRepo.query!(
        "CREATE UNIQUE INDEX #{@table}_unique_ingest_index ON #{@table} (provider, external_event_id)"
      )

      :ok = BusyRepo.stop(30_000)
      # let the dying repo's connections release the db before the pool
      # reopens (connect-time WAL pragmas need a brief write lock)
      Process.sleep(200)

      # The contention substrate: a small pool whose busy_timeout is short
      # enough that a held write lock surfaces the error promptly.
      Application.put_env(:ash_hooks, BusyRepo,
        database: db_path,
        pool_size: 3,
        journal_mode: :wal,
        busy_timeout: 50
      )

      {:ok, _} = BusyRepo.start_link()

      on_exit(fn ->
        :ok = GenServer.stop(BusyRepo)
        File.rm(db_path)
      end)

      :ok
    end

    setup do
      BusyRepo.query!("DELETE FROM #{@table}")
      :ok
    end

    defp ctx do
      %{
        signature: :crypto.mac(:hmac, :sha256, @secret, @raw) |> Base.encode16(case: :lower),
        headers: %{}
      }
    end

    test "an ingest that hits write contention retries and converges to duplicate" do
      # create + process the delivery cleanly first
      assert {:ok, :created, _} = Ingress.ingest(Ledger, :mockish, @raw, ctx())

      parent = self()

      # hold the sqlite write lock ~2x longer than the repo busy_timeout
      holder =
        spawn(fn ->
          # the ack rides an after: a commit that loses a write-lock race
          # with the retry must not strand the test's sync point
          try do
            BusyRepo.transaction(fn ->
              # an UPDATE takes the sqlite write lock (a bare SELECT would not)
              BusyRepo.query!("UPDATE #{@table} SET attempts = attempts")

              send(parent, :locked)

              receive do
                :release -> :ok
              after
                400 -> :ok
              end
            end)
          after
            send(parent, :released)
          end
        end)

      receive do
        :locked -> :ok
      after
        5_000 -> flunk("lock holder never acquired the write lock")
      end

      # WITHOUT the retry this is the documented transient error; WITH it,
      # the upsert is re-attempted after the lock releases and converges
      assert {:ok, :duplicate, delivery} = Ingress.ingest(Ledger, :mockish, @raw, ctx())
      assert delivery.status == :processed

      send(holder, :release)
      assert_receive :released, 5_000

      assert [%{status: :processed, attempts: 1}] =
               Ash.read!(Ledger, authorize?: false)
    end

    test "a claim that hits write contention retries rather than erroring" do
      assert {:ok, :created, _} = Ingress.ingest(Ledger, :mockish, @raw, ctx())

      # strand the row back to :received so it is claimable
      BusyRepo.query!("UPDATE #{@table} SET status = 'received', fencing_token = 0, attempts = 0")

      parent = self()

      holder =
        spawn(fn ->
          try do
            BusyRepo.transaction(fn ->
              BusyRepo.query!("UPDATE #{@table} SET attempts = attempts")
              send(parent, :locked)

              receive do
                :release -> :ok
              after
                400 -> :ok
              end
            end)
          after
            send(parent, :released)
          end
        end)

      receive do
        :locked -> :ok
      after
        5_000 -> flunk("lock holder never acquired the write lock")
      end

      row = Ash.read_one!(Ledger, authorize?: false)

      assert {:ok, token, claimed} = Ingress.claim_delivery(Ledger, row.id)
      assert token == 1
      assert claimed.status == :claimed

      send(holder, :release)
      assert_receive :released, 5_000
    end
  end
end
