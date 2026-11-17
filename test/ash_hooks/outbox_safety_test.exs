Code.require_file("outbox_process.exs", __DIR__)
Code.require_file("outbox_resources.exs", __DIR__)

defmodule AshHooks.OutboxSafety.OtherRepo do
  use AshSqlite.Repo, otp_app: :ash_hooks
  def write_transactions?, do: true
  def min_sqlite_version, do: %Version{major: 3, minor: 54, patch: 1}
end

defmodule AshHooks.OutboxSafety.Nontransactional do
  use Ash.Resource,
    domain: AshHooks.OutboxSafety.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshHooks.OutboundOutbox]

  attributes do
    attribute :org_id, :string, allow_nil?: false
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  actions do
    defaults [:read]
  end

  outbox do
    declarations [{AshHooks.OutboxFixtures.SQLite.Emitter, :changed}]
    delivery_routes default: nil
    deduplication_horizon_seconds 3600
  end
end

defmodule AshHooks.OutboxSafety.Caller do
  use Ash.Resource, domain: AshHooks.OutboxSafety.Domain, data_layer: AshSqlite.DataLayer

  sqlite do
    table "outbox_sqlite_emitters"
    repo(AshHooks.OutboxSafety.OtherRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :org_id, :string, allow_nil?: false
    attribute :value, :string, public?: true
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  actions do
    default_accept :*
    defaults [:read]

    create :create do
      primary? true

      change {AshHooks.Changes.Publish,
              outbox: AshHooks.OutboxFixtures.SQLite.Outbox,
              declaration: {AshHooks.OutboxFixtures.SQLite.Emitter, :changed},
              build: {AshHooks.OutboxFixtures.SQLite.Runtime, :build}}
    end
  end
end

defmodule AshHooks.OutboxSafety.Domain do
  use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

  resources do
    resource AshHooks.OutboxSafety.Nontransactional
    resource AshHooks.OutboxSafety.Caller
  end
end

defmodule AshHooks.OutboxSafetyTest do
  use ExUnit.Case, async: false
  alias AshHooks.OutboxAcceptance, as: Cases
  alias AshHooks.OutboxSafety.{Caller, OtherRepo}
  alias AshHooks.Verifiers.OutboundReferences

  setup_all do
    f = Cases.setup(AshHooks.OutboxFixtures.SQLite)
    Application.put_env(:ash_hooks, OtherRepo, f.repo.config())
    {:ok, pid} = OtherRepo.start_link()
    Process.unlink(pid)

    on_exit(fn ->
      Supervisor.stop(pid)
      Application.delete_env(:ash_hooks, OtherRepo)
    end)

    {:ok, f}
  end

  setup f do
    Cases.clean(f)
  end

  test "A2 and A15 nontransactional and different repositories refuse before an outbox statement",
       f do
    event = Cases.event()

    assert {{:error, :nontransactional_outbox}, []} =
             Cases.count_queries(f, fn ->
               AshHooks.publish(
                 AshHooks.OutboxSafety.Nontransactional,
                 {f.emitter, :changed},
                 event,
                 tenant: "tenant-a"
               )
             end)

    assert {{:error, :publication_repository_mismatch}, []} =
             Cases.count_queries(f, fn ->
               Cases.publish(f, event, caller_resource: Caller)
             end)

    assert {{:error, _}, queries} =
             Cases.count_queries(f, fn ->
               Ash.create(Caller, %{value: "rolled back"},
                 tenant: "tenant-a",
                 authorize?: false
               )
             end)

    refute Enum.any?(queries, &String.contains?(&1, Cases.table(f.outbox)))

    assert {{:error, _}, queries} =
             Cases.count_queries(f, fn ->
               Ash.create(f.emitter, %{value: "context rollback"},
                 tenant: "tenant-a",
                 authorize?: false,
                 context: %{data_layer: %{repo: OtherRepo}}
               )
             end)

    refute Enum.any?(queries, &String.contains?(&1, Cases.table(f.outbox)))
    assert Cases.rows(f, :emitter) == []
    assert Cases.rows(f, :outbox) == []
  end

  test "A15 the extension rejects a statically mismatched publishing repository", f do
    assert_raise Spark.Error.DslError, ~r/same transactional data layer/, fn ->
      OutboundReferences.verify(Caller.spark_dsl_config())
    end

    assert Cases.rows(f, :outbox) == []
  end

  test "A15 static verification refuses absent repositories and defers dynamic repo callbacks", f do
    alias Spark.Dsl.Transformer
    state = f.emitter.spark_dsl_config()

    for invalid <- [
          Transformer.persist(state, :data_layer, Ash.DataLayer.Ets),
          AshHooks.OutboxFixtures.Postgres.Emitter.spark_dsl_config()
          |> Transformer.set_option([:postgres], :repo, nil)
        ] do
      assert_raise Spark.Error.DslError, ~r/same transactional data layer/, fn ->
        OutboundReferences.verify(invalid)
      end
    end

    dynamic = Transformer.set_option(state, [:sqlite], :repo, {__MODULE__, :repo, []})
    assert :ok = OutboundReferences.verify(dynamic)
    assert Cases.rows(f, :outbox) == []
  end

  test "A2 a genuine dynamic repository instance commits, rolls back and fans out", f do
    {:ok, pid} = f.repo.start_link(name: nil)
    Process.unlink(pid)
    previous = f.repo.put_dynamic_repo(pid)

    try do
      event = Cases.event()

      assert {:ok, :ok} =
               Cases.transaction(f, fn ->
                 assert {:ok, :accepted} = Cases.publish(f, event, dynamic_repo: pid)
                 :ok
               end)

      assert :done = Cases.fanout(f, event.id)
      rolled_back = Cases.event()

      assert {:error, :undo} =
               Cases.transaction(f, fn ->
                 assert {:ok, :accepted} = Cases.publish(f, rolled_back, dynamic_repo: pid)
                 f.repo.rollback(:undo)
               end)

      assert is_nil(Cases.publication(f, rolled_back.id))

      assert {{:error, :publication_repository_mismatch}, []} =
               Cases.count_queries(f, fn ->
                 Cases.publish(f, Cases.event(), dynamic_repo: previous)
               end)
    after
      f.repo.put_dynamic_repo(previous)
      Supervisor.stop(pid)
    end
  end
end
