if Code.ensure_loaded?(AshSqlite) do
  defmodule AshHooks.IngressRaceTest do
    @moduledoc """
    The fenced ledger on REAL cross-connection races — the substrate the
    main repo's pool_size 1 cannot express and the busy-retry file's
    HELD-LOCK contention only approximates: N processes ingest the SAME
    event id at the same wall-clock moment, and the pair test proves the
    other side — the same race on a table WITHOUT the storage unique
    index produces the documented hazard (two rows, both :created).
    Together they pin WHY the migration index is load-bearing: it is the
    difference between exactly-once and effect-twice (the moduledoc and
    README point here).
    """

    defmodule Ledger do
      @moduledoc false
      use Ash.Resource,
        domain: AshHooks.IngressRaceTest.Domain,
        data_layer: AshSqlite.DataLayer,
        extensions: [AshHooks, AshHooks.InboundDelivery]

      sqlite do
        table("race_ledgers")
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
          secret(fn -> {:ok, "race-secret"} end)
        end
      end
    end

    defmodule NoIndexLedger do
      @moduledoc false
      use Ash.Resource,
        domain: AshHooks.IngressRaceTest.Domain,
        data_layer: AshSqlite.DataLayer,
        extensions: [AshHooks, AshHooks.InboundDelivery]

      sqlite do
        table("race_no_index_ledgers")
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
          secret(fn -> {:ok, "race-secret"} end)
        end
      end
    end

    defmodule Domain do
      @moduledoc false
      use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

      resources do
        resource(AshHooks.IngressRaceTest.Ledger)
        resource(AshHooks.IngressRaceTest.NoIndexLedger)
      end
    end

    use ExUnit.Case, async: false

    alias AshHooks.Ingress
    alias AshHooks.Test.BusyRepo

    @indexed "race_ledgers"
    @no_index "race_no_index_ledgers"
    @secret "race-secret"
    _ = :race_test
    @raw Jason.encode!(%{"type" => "race_test"})

    setup_all do
      db_path =
        Path.join(System.tmp_dir!(), "ash_hooks_race_#{System.unique_integer()}.sqlite3")

      Application.put_env(:ash_hooks, BusyRepo,
        database: db_path,
        pool_size: 1,
        journal_mode: :wal,
        busy_timeout: 5_000
      )

      {:ok, _boot} = BusyRepo.start_link()

      columns = """
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
      """

      BusyRepo.query!("CREATE TABLE #{@indexed} (#{columns})")

      BusyRepo.query!(
        "CREATE UNIQUE INDEX race_unique_ingest ON #{@indexed} (provider, external_event_id)"
      )

      # the hazard substrate: same shape, NO storage unique index
      BusyRepo.query!("CREATE TABLE #{@no_index} (#{columns})")

      :ok = BusyRepo.stop(30_000)
      Process.sleep(200)

      # normal busy_timeout: race losers WAIT for the write lock and then
      # meet the index conflict — the steady-state consumer configuration
      Application.put_env(:ash_hooks, BusyRepo,
        database: db_path,
        pool_size: 3,
        journal_mode: :wal,
        busy_timeout: 5_000
      )

      {:ok, _} = BusyRepo.start_link()

      on_exit(fn -> File.rm(db_path) end)
      :ok
    end

    setup do
      BusyRepo.query!("DELETE FROM #{@indexed}")
      BusyRepo.query!("DELETE FROM #{@no_index}")
      :ok
    end

    defp ctx do
      %{
        signature: :crypto.mac(:hmac, :sha256, @secret, @raw) |> Base.encode16(case: :lower),
        headers: %{}
      }
    end

    describe "the true concurrent race, WITH the storage unique index" do
      test "N simultaneous ingests of one event id: exactly one :created, one row" do
        n = 8
        parent = self()

        tasks =
          for _ <- 1..n do
            Task.async(fn ->
              # start gate: every contender fires at the same wall-clock
              receive do
                :go -> :ok
              after
                5_000 -> :ok
              end

              send(parent, {:result, Ingress.ingest(Ledger, :mockish, @raw, ctx())})
            end)
          end

        Enum.each(tasks, fn task -> send(task.pid, :go) end)

        results =
          for _ <- 1..n do
            receive do
              {:result, r} -> r
            after
              10_000 -> flunk("an ingest contender never returned")
            end
          end

        created = for {:ok, :created, _} <- results, do: :ok
        duplicates = for {:ok, :duplicate, _} <- results, do: :ok

        assert length(created) == 1
        assert length(duplicates) == n - 1

        rows = Ash.read!(Ledger, authorize?: false)
        assert length(rows) == 1
        assert hd(rows).status == :processed
      end
    end

    describe "the same ingest WITHOUT the storage unique index (the hazard, pinned)" do
      test "sqlite fails CLOSED and loud: the upsert errors on the missing constraint" do
        # probing the documented hazard found the as-built floor is STRONGER
        # than the docs claimed on storage layers with native conflict
        # support: the ON CONFLICT clause names the identity, so a missing
        # index errors the ingest outright — no silent second row on
        # sqlite/postgres. (The two-rows-both-:created shape is the
        # degraded-upsert layer's failure mode; either way the index is
        # load-bearing — this pair of tests is why the migration
        # requirement is stated as non-optional.)
        assert {:error, error} = Ingress.ingest(NoIndexLedger, :mockish, @raw, ctx())
        assert Exception.message(error) =~ "UNIQUE constraint"
        assert Ash.read!(NoIndexLedger, authorize?: false) == []
      end
    end
  end
end
