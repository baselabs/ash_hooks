defmodule AshHooks.CustodySqliteConformanceTest do
  alias AshHooks.Test.Custodian

  use AshHooks.Custody.Conformance, custodian: AshHooks.Test.Custodian

  setup do
    Custodian.setup_store!()
    on_exit(&Custodian.drop_store!/0)
    :ok
  end
end

defmodule AshHooks.CustodyPostgresConformanceTest do
  use ExUnit.Case, async: false
  alias AshHooks.TestPostgres.Custodian
  @moduletag :postgres

  use AshHooks.Custody.Conformance, custodian: AshHooks.TestPostgres.Custodian

  setup do
    Custodian.setup_store!()
    on_exit(&Custodian.drop_store!/0)
    :ok
  end
end

defmodule AshHooks.BrokenCustodian do
  alias AshHooks.Test.Custodian

  # An intentional tenant-binding mutation over the same real SQLite table.
  defdelegate store(ref, material, tenant, kind), to: AshHooks.Test.Custodian
  defdelegate sign(ref, tenant, kind, input), to: AshHooks.Test.Custodian
  defdelegate verify(ref, tenant, kind, input, mac), to: AshHooks.Test.Custodian
  defdelegate public_key(ref, tenant, kind), to: AshHooks.Test.Custodian
  defdelegate fingerprint(ref, tenant, kind), to: AshHooks.Test.Custodian

  def destroy(ref, _tenant), do: Custodian.destroy(ref, "tenant-a")
end

defmodule AshHooks.BrokenCustodianConformance do
  use AshHooks.Custody.Conformance, custodian: AshHooks.BrokenCustodian, register: false
end

defmodule AshHooks.CustodyConformanceTripwireTest do
  use ExUnit.Case, async: false

  alias AshHooks.BrokenCustodianConformance
  alias AshHooks.Test.Custodian

  test "the shipped template compiles without ExUnit on the code path" do
    program = ~S"""
    true = :code.del_path(:code.lib_dir(:ex_unit, :ebin))
    false = Code.ensure_loaded?(ExUnit.Case)
    false = Code.ensure_loaded?(ExUnit.CaseTemplate)
    Code.compile_file("lib/ash_hooks/custody/conformance.ex")
    true = function_exported?(AshHooks.Custody.Conformance, :"MACRO-__using__", 2)
    """

    {output, status} =
      System.cmd(System.find_executable("elixir"), ["-e", program], stderr_to_stdout: true)

    assert status == 0, output
    refute :ex_unit in Application.spec(:ash_hooks, :applications)
  end

  test "the template fails a custodian whose wrong-tenant destroy destroys the bound key" do
    Custodian.setup_store!()
    on_exit(&Custodian.drop_store!/0)
    module = BrokenCustodianConformance

    test =
      Enum.find(module.__ex_unit__().tests, fn test ->
        Atom.to_string(test.name) =~ "store under A then destroy under B"
      end)

    assert test, "the wrong-tenant destroy contract must have a generated test"

    assert_raise ExUnit.AssertionError, ~r/tenant_mismatch/, fn ->
      apply(module, test.name, [%{}])
    end
  end
end
