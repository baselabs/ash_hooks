defmodule AshHooks.KeyIssuingTest do
  use ExUnit.Case, async: false
  alias AshHooks.Test.KeyIssuingCases, as: Cases

  setup_all do
    Cases.setup_all(__MODULE__, AshSqlite.DataLayer, AshHooks.Test.RegistryRepo, "key_issuing")
  end

  setup ctx do
    Cases.clean(ctx)
  end

  for name <- Cases.cases() do
    if name in Cases.receiver_cases(), do: @tag(:real_receiver)
    @tag issuing_case: name
    test "key issuing #{name}", ctx do
      log = ExUnit.CaptureLog.capture_log(fn -> apply(Cases, unquote(name), [ctx]) end)
      refute log =~ "private_backend"
    end
  end

  @tag :real_receiver
  test "issued disclosure verifies at the receiver", ctx do
    Cases.real_delivery(ctx)
  end
end
