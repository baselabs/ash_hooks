defmodule AshHooks.KeyRegistryPostgresTest do
  use ExUnit.Case, async: false
  alias AshHooks.Test.KeyRegistryCases, as: Cases
  @moduletag :postgres

  setup_all do
    Cases.setup_all(
      __MODULE__,
      AshPostgres.DataLayer,
      AshHooks.TestPostgres.Repo,
      "pg_key_registry"
    )
  end

  setup context do
    Cases.clean(context)
  end

  for name <- Cases.cases() do
    @tag registry_case: name
    test "registry #{name}", context do
      ExUnit.CaptureLog.capture_log(fn -> apply(Cases, unquote(name), [context]) end)
    end
  end

  @tag registry_case: :attach_timeout_barrier
  test "registry attach_timeout_barrier", context do
    ExUnit.CaptureLog.capture_log(fn -> Cases.attach_timeout_barrier(context) end)
  end
end
