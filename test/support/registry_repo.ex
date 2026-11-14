defmodule AshHooks.Test.RegistryRepo do
  @moduledoc false
  use AshSqlite.Repo, otp_app: :ash_hooks

  @impl AshSqlite.Repo
  def write_transactions?, do: true

  @impl AshSqlite.Repo
  def min_sqlite_version, do: %Version{major: 3, minor: 54, patch: 1}
end

defmodule AshHooks.Test.RegistryOtherRepo do
  @moduledoc false
  use AshSqlite.Repo, otp_app: :ash_hooks
  alias AshHooks.Test.RegistryRepo

  @impl AshSqlite.Repo
  def write_transactions?, do: true

  @impl AshSqlite.Repo
  def min_sqlite_version, do: RegistryRepo.min_sqlite_version()
end
