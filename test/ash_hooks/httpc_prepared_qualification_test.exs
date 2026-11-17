defmodule AshHooks.HttpcPreparedQualificationTest do
  use ExUnit.Case, async: true
  alias AshHooks.Http.Httpc

  test "Httpc does not advertise exact prepared-request transport" do
    Code.ensure_loaded!(Httpc)
    refute function_exported?(Httpc, :send_prepared, 2)
  end
end
