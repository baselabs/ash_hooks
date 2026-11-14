defmodule AshHooks.KeyRegistryTest do
  use ExUnit.Case, async: false
  alias AshHooks.Test.KeyRegistryCases, as: Cases

  setup_all do
    Cases.setup_all(__MODULE__, AshSqlite.DataLayer, AshHooks.Test.RegistryRepo, "key_registry")
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
end
