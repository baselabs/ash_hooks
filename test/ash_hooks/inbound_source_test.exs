defmodule AshHooks.InboundSourceTest do
  use ExUnit.Case, async: false
  alias AshHooks.Test.InboundSourceCases, as: Cases
  alias AshHooks.Test.KeyIssuingCases

  setup_all do
    Cases.setup_all(__MODULE__, AshSqlite.DataLayer, AshHooks.Test.RegistryRepo, "inbound_source")
  end

  setup ctx do
    Cases.clean(ctx)
  end

  for name <- Cases.cases() do
    @tag source_case: name
    test "inbound source #{name}", ctx do
      apply(Cases, unquote(name), [ctx])
    end
  end

  for name <- KeyIssuingCases.source_cases() do
    test "source issuing #{name}", ctx do
      Cases.issuing_case(ctx, unquote(name))
    end
  end
end
