defmodule AshHooks.Test.Repo do
  @moduledoc false
  # Test-only sqlite substrate for the fenced-ledger concurrency tests
  # (ADR-0003 best-effort matrix leg; dev/test-only dep, never ships).
  use AshSqlite.Repo, otp_app: :ash_hooks
end
