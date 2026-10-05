defmodule AshHooks.TestPostgres.Repo do
  @moduledoc false
  # The AshPostgres substrate for the :postgres-tagged consumer suite
  # (CI's postgres job; locally a BaseLabs ephemeral-area Postgres). Not
  # started unless ASH_HOOKS_POSTGRES=1 — every ordinary dev/test run
  # stays on the sqlite repo. Tables are raw DDL (the suite's explicit
  # style), so the ash-functions migration machinery is not in play.
  use AshPostgres.Repo,
    otp_app: :ash_hooks,
    warn_on_missing_ash_functions?: false

  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
end
