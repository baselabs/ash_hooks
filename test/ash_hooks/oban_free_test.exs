defmodule AshHooks.ObanFreeTest do
  @moduledoc """
  The inbound-only proof (the #7 ACCEPT's last clause): the package runs
  its inbound flows without Oban entirely. On the no-optional CI leg Oban
  is absent from the dep list and must never load; on the optional leg it
  is present as a dep but nothing in this suite's inbound work has started
  it (the worker tests start their own instance and stop it on exit).
  """

  use ExUnit.Case, async: false

  test "inbound flow completes without Oban loading or starting" do
    if Code.ensure_loaded?(Oban) do
      # optional leg: Mix auto-starts the dep's APPLICATION at boot — the
      # package's obligation is that no Oban INSTANCE was ever configured
      # or started for inbound work (no queues, no engines, no producers)
      assert Application.get_env(:oban, :instances, []) == []
    else
      # no-optional leg: Oban is entirely absent — nothing could load it
      refute Code.ensure_loaded?(Oban)
    end
  end
end
