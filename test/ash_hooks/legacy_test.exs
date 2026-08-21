defmodule AshHooks.LegacyTest do
  use ExUnit.Case, async: true

  alias AshHooks.Legacy
  import AshHooks.TestAstTripwire

  # INCUMBENT-CAPTURED vectors: commerce_platform's own Signing module was
  # executed first-hand (scratch VM, single stdlib-only file compiled — zero
  # footprint on that read-only tree) over these fixed inputs, and its output
  # captured verbatim. Byte-identity is against executed incumbent code, not a
  # transcription of it.
  @legacy_secret "legacy-incumbent-secret"
  @previous_secret "previous-secret"
  @legacy_body ~s({"order":"ord_1"})
  @legacy_ts 1_614_265_330
  @expected_hex "2d0a6fff1b8e1085ff3fae6929b63d577c08fc45bf5c5b4f90a938f7d074dd73"
  @expected_prev_hex "d602ff7b91030c0f7ee15eb776b7777b311fb661e1e79f4de68194e80fe90420"
  @expected_header "t=1614265330,v1=2d0a6fff1b8e1085ff3fae6929b63d577c08fc45bf5c5b4f90a938f7d074dd73"

  @expected_rotation_header @expected_header <> ",v1prev=" <> @expected_prev_hex

  describe "byte-identity with the incumbent envelope" do
    test "sign/3 emits the exact incumbent signature string" do
      assert Legacy.sign(@legacy_secret, @legacy_body, @legacy_ts) == "v1=" <> @expected_hex
    end

    test "header_value/2 assembles the exact incumbent header" do
      signature = Legacy.sign(@legacy_secret, @legacy_body, @legacy_ts)
      assert Legacy.header_value(signature, @legacy_ts) == @expected_header
    end

    test "rotation emits v1 plus v1prev byte-identically" do
      signature =
        Legacy.sign_with_previous(@legacy_secret, @previous_secret, @legacy_body, @legacy_ts)

      assert signature == "v1=" <> @expected_hex <> ",v1prev=" <> @expected_prev_hex
      assert Legacy.header_value(signature, @legacy_ts) == @expected_rotation_header
    end

    test "headers/4 carries the incumbent header name" do
      assert Legacy.headers(@legacy_secret, nil, @legacy_body, @legacy_ts) == %{
               "x-webhook-signature" => @expected_header
             }
    end
  end

  describe "verify/5 (the legacy oracle)" do
    test "accepts its own emission within the window" do
      header =
        Legacy.header_value(Legacy.sign(@legacy_secret, @legacy_body, @legacy_ts), @legacy_ts)

      assert {:ok, %{unix_ts: @legacy_ts}} =
               Legacy.verify(@legacy_secret, @legacy_body, header, @legacy_ts + 10)
    end

    test "a rotation header still verifies under the CURRENT secret (the incumbent verifier reads v1 only)" do
      header =
        Legacy.header_value(
          Legacy.sign_with_previous(@legacy_secret, @previous_secret, @legacy_body, @legacy_ts),
          @legacy_ts
        )

      assert {:ok, _} = Legacy.verify(@legacy_secret, @legacy_body, header, @legacy_ts + 10)
    end

    test "rejects a body whose FIRST byte was tampered" do
      header =
        Legacy.header_value(Legacy.sign(@legacy_secret, @legacy_body, @legacy_ts), @legacy_ts)

      <<_first, rest::binary>> = @legacy_body
      tampered = <<?x, rest::binary>>

      assert {:error, :invalid_signature} =
               Legacy.verify(@legacy_secret, tampered, header, @legacy_ts + 10)
    end

    test "rejects a signature whose first hex char was tampered" do
      signature = Legacy.sign(@legacy_secret, @legacy_body, @legacy_ts)
      flipped = flip_first_hex_char(signature)
      tampered_header = Legacy.header_value(flipped, @legacy_ts)

      assert {:error, :invalid_signature} =
               Legacy.verify(@legacy_secret, @legacy_body, tampered_header, @legacy_ts + 10)
    end

    test "rejects timestamps outside the replay window (both directions)" do
      header =
        Legacy.header_value(Legacy.sign(@legacy_secret, @legacy_body, @legacy_ts), @legacy_ts)

      assert {:error, :stale_timestamp} =
               Legacy.verify(@legacy_secret, @legacy_body, header, @legacy_ts + 301)

      assert {:error, :stale_timestamp} =
               Legacy.verify(@legacy_secret, @legacy_body, header, @legacy_ts - 301)

      assert {:ok, _} = Legacy.verify(@legacy_secret, @legacy_body, header, @legacy_ts + 300)
    end

    test "rejects malformed headers without raising" do
      for bad <- ["", "garbage", "v1=abc", "t=notanumber,v1=abc", "t=1614265330"] do
        assert {:error, :invalid_signature} =
                 Legacy.verify(@legacy_secret, @legacy_body, bad, @legacy_ts)
      end
    end

    test "fails closed on an empty secret" do
      assert {:error, :invalid_signature} =
               Legacy.verify("", @legacy_body, @expected_header, @legacy_ts + 10)
    end
  end

  defp flip_first_hex_char("v1=" <> hex) do
    <<first, rest::binary>> = hex
    replacement = if first == ?a, do: ?b, else: ?a
    "v1=" <> <<replacement, rest::binary>>
  end

  describe "constant-time compare tripwire (mutation-red gate)" do
    @source_path Path.expand("../../lib/ash_hooks/legacy.ex", __DIR__)

    test "verify compares via :crypto.hash_equals/2, never a bare == on signature material" do
      ast = source_ast(@source_path)

      assert module_calls_constant_time_compare?(ast),
             "the module must compare signature material with :crypto.hash_equals/2"

      refute module_compares_material_with_bare_equality?(ast, [:signature_hex, :expected]),
             "signature hex must not be compared with ==/!=/===/!== directly"
    end

    test "the named mutation (:crypto.hash_equals -> ==) turns the tripwire red" do
      mutated = mutate_hash_equals_to_equals(source_ast(@source_path))
      refute module_calls_constant_time_compare?(mutated)
    end
  end
end
