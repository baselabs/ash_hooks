defmodule AshHooks.CustodyPublicKeyTest do
  use ExUnit.Case, async: true
  alias AshHooks.Custody.PublicKey
  alias AshHooks.Errors.Invalid.KeyKindMismatch
  alias AshHooks.Provider.Signature

  test "standard public pins require the whpk envelope and keep the original public value" do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    key = "whpk_" <> Base.encode64(public)
    assert {:ok, pin} = PublicKey.new(key, {:standard_webhooks, :v1a})
    assert pin.key == key
    signature = :crypto.sign(:eddsa, :none, "body", [private, :ed25519]) |> Base.encode64()
    assert :ok = Signature.ed25519("body", signature, pin)
    assert {:error, %KeyKindMismatch{}} = Signature.hmac("body", Base.encode16(<<0::256>>), pin)

    for bad <- [public, "whpk_!", "whpk_" <> Base.encode64("short"), nil],
        do: assert({:error, %KeyKindMismatch{}} = PublicKey.new(bad, {:standard_webhooks, :v1a}))

    for kind <- [nil, :unknown, {:standard_webhooks, :v1}, {:sender_hmac, :sha256}],
        do: assert({:error, %KeyKindMismatch{}} = PublicKey.new(public, kind))

    assert {:error, %KeyKindMismatch{}} = PublicKey.new("undecodable", :ed25519)
  end
end
