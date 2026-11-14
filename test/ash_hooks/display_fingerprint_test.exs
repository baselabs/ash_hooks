defmodule AshHooks.DisplayFingerprintTest do
  use ExUnit.Case, async: false

  alias AshHooks.{Custody, Signing}
  alias AshHooks.Errors.Invalid.KeyKindMismatch
  alias AshHooks.Test.Custodian

  # Independent fingerprint vectors, using the fixed seed/key bytes 0 through 31.
  @material :binary.list_to_bin(Enum.to_list(0..31))
  @v1 "SHA256:vMTxUlKthcdCjADlQC2iaQ"
  @v1a "SHA256:CFS9a61CisKebjRtMRdIdQ"

  test "both spec labels match literal vectors and Ed25519 pair halves agree" do
    {public, _private} = :crypto.generate_key(:eddsa, :ed25519, @material)

    assert {:ok, @v1} = Signing.display_fingerprint("whsec_" <> Base.encode64(@material))
    assert {:ok, @v1a} = Signing.display_fingerprint("whsk_" <> Base.encode64(@material))
    assert {:ok, @v1a} = Signing.display_fingerprint("whpk_" <> Base.encode64(public))

    assert {:ok, @v1} =
             Signing.display_fingerprint("whsec_" <> Base.encode64(@material, padding: false))
  end

  test "only spec-shaped keys with the specified decoded bounds have a fingerprint" do
    for size <- [24, 64] do
      assert {:ok, "SHA256:" <> _} =
               Signing.display_fingerprint("whsec_" <> Base.encode64(:binary.copy(<<1>>, size)))
    end

    invalid =
      [nil, 123, @material, Base.encode64(@material), "whsec_!", "whsk_!", "whpk_!"] ++
        for {prefix, sizes} <- [
              {"whsec_", [0, 1, 23, 65]},
              {"whsk_", [0, 31, 33]},
              {"whpk_", [0, 31, 33]}
            ],
            size <- sizes do
          prefix <> Base.encode64(:binary.copy(<<1>>, size))
        end

    for value <- invalid do
      assert {:error, :not_a_spec_key} = Signing.display_fingerprint(value)
    end
  end

  test "custody displays the same vectors without disclosing stored material" do
    Custodian.setup_store!()
    on_exit(&Custodian.drop_store!/0)

    for {kind, expected} <- [{{:standard_webhooks, :v1}, @v1}, {{:standard_webhooks, :v1a}, @v1a}] do
      ref = "ahk_" <> Ash.UUIDv7.generate()
      assert :ok = Custodian.store(ref, @material, "tenant-a", kind)
      key = struct!(Custody.Key, custodian: Custodian, ref: ref, tenant: "tenant-a", kind: kind)
      assert {:ok, ^expected} = Custody.display_fingerprint(key)
    end
  end

  test "fingerprint kind_mismatch is classified as KeyKindMismatch" do
    Custodian.setup_store!()
    on_exit(&Custodian.drop_store!/0)
    ref = "ahk_" <> Ash.UUIDv7.generate()
    assert :ok = Custodian.store(ref, @material, nil, {:standard_webhooks, :v1})

    key =
      struct!(Custody.Key,
        custodian: Custodian,
        ref: ref,
        tenant: nil,
        kind: {:standard_webhooks, :v1a}
      )

    assert {:error, error} = Custody.display_fingerprint(key)
    assert error.__struct__ == KeyKindMismatch
  end

  test "every as-issued kind refuses a display fingerprint before invoking custody" do
    for kind <- [
          {:legacy_hmac, :sha256}
          | Enum.map([:sha1, :sha256, :sha384, :sha512], &{:sender_hmac, &1})
        ] do
      key = struct!(Custody.Key, custodian: nil, ref: "unused", tenant: nil, kind: kind)
      assert {:error, :no_fingerprint} = Custody.display_fingerprint(key)
    end
  end
end
