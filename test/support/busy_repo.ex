defmodule AshHooks.Test.BusyRepo do
  @moduledoc false
  # Throwaway repo for the transient-busy retry tests — configured and
  # started by that test file itself (pool/busy_timeout differ per phase).
  use AshSqlite.Repo, otp_app: :ash_hooks
end
