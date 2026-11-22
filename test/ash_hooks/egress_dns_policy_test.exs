defmodule AshHooks.EgressDnsPolicyTest do
  use ExUnit.Case, async: false

  alias AshHooks.Ssrf
  alias ExUnit.AssertionError

  test "one disallowed DNS answer refuses the entire bag in either order and family" do
    public = {8, 8, 8, 8}
    private = {127, 0, 0, 1}
    public_v6 = {0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}
    private_v6 = {0, 0, 0, 0, 0, 65_535, 0x7F00, 1}

    assert {:ok, [^public, ^public_v6]} = Ssrf.classify_addresses([public, public_v6])

    for answers <- [
          [public, private],
          [private, public],
          [public_v6, private_v6],
          [private_v6, public_v6]
        ] do
      assert {:error, :unsafe} = Ssrf.classify_addresses(answers)
    end

    # Red-proof the exact all-versus-any mutation in an isolated copy of the
    # production policy. No resolver, network, or live module is replaced.
    mutant = Module.concat(__MODULE__, :PolicyMutation)
    source = File.read!("lib/ash_hooks/ssrf.ex")
    guard = "Enum.all?(addresses, &public_address?/1)"
    assert source =~ guard

    mutated =
      source
      |> String.replace("defmodule AshHooks.Ssrf do", "defmodule #{inspect(mutant)} do")
      |> String.replace(guard, "Enum.any?(addresses, &public_address?/1)")

    check = fn module ->
      assert {:error, :unsafe} = module.classify_addresses([public, private])
    end

    check.(Ssrf)

    try do
      Code.compile_string(mutated)
      assert_raise AssertionError, fn -> check.(mutant) end
    after
      :code.delete(mutant)
      :code.purge(mutant)
    end
  end
end
