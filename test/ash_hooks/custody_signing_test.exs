defmodule AshHooks.CustodySigningTest do
  use ExUnit.Case, async: false
  alias AshHooks.Test.CustodySigningCases, as: Cases

  setup_all do
    Cases.setup_all(
      __MODULE__,
      AshSqlite.DataLayer,
      AshHooks.Test.RegistryRepo,
      "custody_signing"
    )
  end

  setup ctx do
    Cases.clean(ctx)
  end

  for name <- Cases.cases() do
    test "custody #{name}", ctx do
      log = ExUnit.CaptureLog.capture_log(fn -> apply(Cases, unquote(name), [ctx]) end)
      refute log =~ "private_backend"
    end
  end

  @tag :real_receiver
  test "custody signs both algorithms, legacy, mixed slots and test_send at the receiver", ctx do
    Cases.real_delivery(ctx)
  end
end
