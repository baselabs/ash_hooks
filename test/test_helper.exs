# Test bootstrap: the fenced-ledger tests run on a real sqlite unique index
# (probe 2026-08-21: ETS cannot express storage-level uniqueness or
# conditional-update atomicity). One throwaway db per run, WAL on so
# concurrent writers serialize instead of erroring; per-test-file tables are
# created by each file's setup.

db_path = Path.join(System.tmp_dir!(), "ash_hooks_test_#{Ash.UUID.generate()}.sqlite3")

# WAL + busy timeout via repo config — applied per connection at open
# (post-start PRAGMA queries race the pool's connection init and surface
# boot-time "database is locked" errors).
# pool_size 1: the fences under test are STATEMENT-level (unique-index
# upsert; WHERE-gated atomic update) — sqlite enforces both on a single
# connection. A wider pool adds only exqlite cross-connection artifacts
# (schema-visibility races surfaced as "ON CONFLICT does not match any
# UNIQUE constraint", boot-time connect locks), never stronger guarantees.
Application.put_env(:ash_hooks, AshHooks.Test.Repo,
  database: db_path,
  pool_size: 1,
  journal_mode: :wal,
  busy_timeout: 5_000,
  synchronous: :normal
)

{:ok, _} = AshHooks.Test.Repo.start_link()

# The AshPostgres consumer leg: ASH_HOOKS_POSTGRES=1 starts the PG repo
# and includes the :postgres-tagged suite (CI's postgres job — a Linux
# runner with a Postgres service; locally, a BaseLabs ephemeral-area
# Postgres pointed at by the env below). Without the flag the suite is
# excluded and ordinary dev/test runs need no Postgres at all.
postgres? = System.get_env("ASH_HOOKS_POSTGRES") == "1"
httpbun? = System.get_env("ASH_HOOKS_HTTPBUN") == "1"

if postgres? do
  Application.put_env(:ash_hooks, AshHooks.TestPostgres.Repo,
    hostname: System.get_env("ASH_HOOKS_TEST_PG_HOST", "localhost"),
    port: String.to_integer(System.get_env("ASH_HOOKS_TEST_PG_PORT", "5432")),
    username: System.get_env("ASH_HOOKS_TEST_PG_USER", "postgres"),
    password: System.get_env("ASH_HOOKS_TEST_PG_PASSWORD", "postgres"),
    database: System.get_env("ASH_HOOKS_TEST_PG_DATABASE", "ash_hooks_test"),
    pool_size: 5
  )

  {:ok, _} = AshHooks.TestPostgres.Repo.start_link()
end

ExUnit.start(
  exclude: if(postgres?, do: [], else: [:postgres]) ++ if(httpbun?, do: [], else: [:httpbun]),
  after_suite: [
    fn _stats ->
      if repo_pid = Process.whereis(AshHooks.Test.Repo), do: Supervisor.stop(repo_pid)
      for suffix <- ["", "-shm", "-wal"], do: File.rm(db_path <> suffix)
    end
  ]
)
