# Test bootstrap: the fenced-ledger tests run on a real sqlite unique index
# (probe 2026-08-21: ETS cannot express storage-level uniqueness or
# conditional-update atomicity). One throwaway db per run, WAL on so
# concurrent writers serialize instead of erroring; per-test-file tables are
# created by each file's setup.

db_path = Path.join(System.tmp_dir!(), "ash_hooks_test_#{System.unique_integer()}.sqlite3")

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

ExUnit.start(after_suite: [fn _stats -> File.rm(db_path) end])
