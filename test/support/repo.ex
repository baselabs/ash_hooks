defmodule AshHooks.Test.Repo do
  @moduledoc false
  # Test-only sqlite substrate for the fenced-ledger concurrency tests
  # (ADR-0003 best-effort matrix leg; dev/test-only dep, never ships).
  use AshSqlite.Repo, otp_app: :ash_hooks

  # The tests run on the SQLite exqlite bundles (no system SQLite), so the
  # oldest version this repo meets is exqlite's bundled one: 3.54.1 in the
  # locked exqlite 0.43.0 (deps/exqlite/c_src/sqlite3.h).
  @impl AshSqlite.Repo
  def min_sqlite_version, do: %Version{major: 3, minor: 54, patch: 1}
end
