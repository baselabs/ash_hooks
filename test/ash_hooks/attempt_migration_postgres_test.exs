defmodule AshHooks.AttemptMigrationPostgresTest do
  @moduledoc """
  Proves the attempt-history and endpoint-capture migrations up, down, and
  up again on seeded rows against real PostgreSQL — the schema change
  adopters run is reversible and the data story survives a round trip
  (the migration is consumer-owned; this is the tutorial's documented DDL
  run as a real Ecto migration through Ecto.Migrator).
  """

  use ExUnit.Case, async: false

  alias AshHooks.TestPostgres.Repo

  @moduletag :postgres
  @version 20_260_110_000_001

  # The tutorial's documented attempt-history + capture DDL as a real
  # Ecto migration (reversible: create/drop, add/remove)
  defmodule AttemptHistoryMigration do
    @moduledoc false
    use Ecto.Migration

    def change do
      create table(:migration_proof_attempts, primary_key: false) do
        add(:id, :uuid, primary_key: true)
        add(:delivery_pk, :jsonb, null: false)
        add(:endpoint_id, :uuid, null: false)
        add(:event_uuid, :text, null: false)
        add(:event_type, :text, null: false)
        add(:attempt, :integer, null: false)
        add(:outcome, :text, null: false)
        add(:reason, :text)
        add(:response_status, :integer)
        add(:response_snippet, :text)
        add(:response_headers, :jsonb)
        add(:latency_ms, :integer)
        add(:signing_key_ref, :text)
        add(:attempted_at, :utc_datetime_usec, null: false)
      end

      create(unique_index(:migration_proof_attempts, [:delivery_pk, :attempt]))

      alter table(:migration_proof_endpoints) do
        add(:response_capture, :boolean, null: false, default: false)
        add(:response_capture_max_bytes, :integer, null: false, default: 2048)
        add(:response_capture_retention_seconds, :integer, null: false, default: 2_592_000)
        add(:response_header_allowlist, {:array, :text}, null: false, default: [])
      end
    end
  end

  setup_all do
    Repo.query!("DROP TABLE IF EXISTS migration_proof_attempts")
    Repo.query!("DROP TABLE IF EXISTS migration_proof_endpoints")

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS schema_migrations (version bigint, inserted_at timestamp)
    """)

    Repo.query!("DELETE FROM schema_migrations WHERE version = #{@version}")

    Repo.query!("""
    CREATE TABLE migration_proof_endpoints (
      id UUID PRIMARY KEY, url TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'enabled',
      secret_ref TEXT NOT NULL, previous_secret_ref TEXT, legacy_secret_ref TEXT,
      legacy_previous_secret_ref TEXT
    )
    """)

    Repo.query!("""
    INSERT INTO migration_proof_endpoints (id, url, secret_ref)
    VALUES (gen_random_uuid(), 'https://hooks.example.test/accept', 'proof-ref')
    """)

    on_exit(fn ->
      Repo.query!("DROP TABLE IF EXISTS migration_proof_attempts")
      Repo.query!("DROP TABLE IF EXISTS migration_proof_endpoints")
      Repo.query!("DELETE FROM schema_migrations WHERE version = #{@version}")
    end)

    :ok
  end

  test "the migration runs up, down, and up on seeded rows" do
    assert :ok = Ecto.Migrator.up(Repo, @version, AttemptHistoryMigration)

    Repo.query!("""
    INSERT INTO migration_proof_attempts
      (id, delivery_pk, endpoint_id, event_uuid, event_type, attempt, outcome,
       reason, response_status, response_snippet, response_headers, latency_ms,
       signing_key_ref, attempted_at)
    SELECT gen_random_uuid(),
           jsonb_build_object('id', gen_random_uuid()::text),
           id, 'msg_migration_proof', 'order_paid', 1, 'succeeded',
           NULL, 200, '200 json token=application/json',
           jsonb_build_object('content-type', 'application/json'), 12, 'proof-ref', now()
    FROM migration_proof_endpoints LIMIT 1
    """)

    assert %{num_rows: 1} =
             Repo.query!(
               "SELECT 1 FROM migration_proof_attempts WHERE event_uuid = 'msg_migration_proof'"
             )

    assert %{num_rows: 1} =
             Repo.query!(
               "SELECT 1 FROM migration_proof_endpoints WHERE response_capture = false AND response_capture_max_bytes = 2048"
             )

    # DOWN on seeded rows: reversible while data exists
    assert :ok = Ecto.Migrator.down(Repo, @version, AttemptHistoryMigration)

    assert %{rows: [[true]]} =
             Repo.query!("SELECT to_regclass('migration_proof_attempts') IS NULL")

    assert %{num_rows: 0} =
             Repo.query!(
               "SELECT 1 FROM information_schema.columns WHERE table_name = 'migration_proof_endpoints' AND column_name = 'response_capture'"
             )

    # UP again: the schema returns
    assert :ok = Ecto.Migrator.up(Repo, @version, AttemptHistoryMigration)

    assert %{num_rows: 1} =
             Repo.query!(
               "SELECT 1 FROM information_schema.columns WHERE table_name = 'migration_proof_attempts' AND column_name = 'attempted_at'"
             )
  end
end
