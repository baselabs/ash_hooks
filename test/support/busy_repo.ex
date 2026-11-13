defmodule AshHooks.Test.BusyRepo do
  @moduledoc false
  # Throwaway repo for the transient-busy retry tests — configured and
  # started by that test file itself (pool/busy_timeout differ per phase).
  use AshSqlite.Repo, otp_app: :ash_hooks

  # The tests run on the SQLite exqlite bundles (no system SQLite), so the
  # oldest version this repo meets is exqlite's bundled one: 3.54.1 in the
  # locked exqlite 0.43.0 (deps/exqlite/c_src/sqlite3.h).
  @impl AshSqlite.Repo
  def min_sqlite_version, do: %Version{major: 3, minor: 54, patch: 1}
end
