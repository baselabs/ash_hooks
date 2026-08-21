defmodule AshHooks.SigningTest do
  use ExUnit.Case, async: true

  alias AshHooks.Signing
  import AshHooks.TestAstTripwire

  # Foreign conformance vector — the official Go reference library's own
  # TestWebhookSign constants, read first-hand in the SW spec repo
  # (libraries/go/webhook_test.go). Byte-for-byte reproduction required.
  @go_key "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"
  @go_msg_id "msg_p5jXN8AQM9LWM0D4loKWxJek"
  @go_ts 1_614_265_330
  @go_payload ~s({"test": 2432232314})
  @go_sig "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="

  # RFC 8032 §7.1 TEST 1 — Ed25519 known-answer; constants substrate-verified
  # against :crypto at authoring time. Used as the fixed test keypair AND as
  # the raw-EdDSA shape canary.
  @rfc_seed_hex "9D61B19DEFFD5A60BA844AF492EC2CC44449C5697B326919703BAC031CAE7F60"
  @rfc_pub_hex "D75A980182B10AB7D54BFED3C964073A0EE172F3DAA62325AF021A68F707511A"
  @rfc_sig_hex "E5564300C360AC729086E2CC806E828A84877F1EB8E5D974D873E065224901555FB8821590A33BACC61E39701CF9B46BD25BF5F0595BBE24655141438E7A100B"

  @whsk "whsk_" <> Base.encode64(Base.decode16!(@rfc_seed_hex))
  @whpk "whpk_" <> Base.encode64(Base.decode16!(@rfc_pub_hex))

  defp sw_headers(msg_id, ts, signature) do
    %{
      "webhook-id" => msg_id,
      "webhook-timestamp" => Integer.to_string(ts),
      "webhook-signature" => signature
    }
  end

  describe "sign/4 — v1 foreign vector" do
    test "reproduces the Go reference signature byte-for-byte" do
      assert Signing.sign(@go_msg_id, @go_ts, @go_payload, @go_key) == @go_sig
    end

    test "accepts the secret without the whsec_ prefix (reference parity)" do
      assert Signing.sign(@go_msg_id, @go_ts, @go_payload, "MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw") ==
               @go_sig
    end
  end

  describe "sign/4 validation (fail loud at the send path)" do
    test "rejects secrets shorter than 24 decoded bytes" do
      assert_raise ArgumentError, ~r/24/, fn ->
        Signing.sign(@go_msg_id, @go_ts, @go_payload, "whsec_" <> Base.encode64(<<0::128>>))
      end
    end

    test "rejects secrets longer than 64 decoded bytes" do
      assert_raise ArgumentError, ~r/64/, fn ->
        Signing.sign(
          @go_msg_id,
          @go_ts,
          @go_payload,
          "whsec_" <> Base.encode64(:binary.copy(<<0>>, 65))
        )
      end
    end

    test "rejects empty secrets (bare and whsec_-only)" do
      assert_raise ArgumentError, ~r/secret/, fn ->
        Signing.sign(@go_msg_id, @go_ts, @go_payload, "")
      end

      assert_raise ArgumentError, ~r/secret/, fn ->
        Signing.sign(@go_msg_id, @go_ts, @go_payload, "whsec_")
      end
    end

    test "rejects a msg_id containing the canonical-string delimiter" do
      assert_raise ArgumentError, ~r/msg_id/, fn ->
        Signing.sign("msg_evil.attempt", @go_ts, @go_payload, @go_key)
      end
    end

    test "rejects an empty msg_id and non-integer timestamps (guard-level)" do
      assert_raise FunctionClauseError, fn -> Signing.sign("", @go_ts, @go_payload, @go_key) end

      assert_raise FunctionClauseError, fn ->
        Signing.sign(@go_msg_id, "1614265330", @go_payload, @go_key)
      end
    end
  end

  describe "sign_ed25519/4 and ed25519 substrate" do
    test "the OTP key shapes still satisfy RFC 8032 TEST 1 (substrate canary)" do
      seed = Base.decode16!(@rfc_seed_hex)

      priv =
        {:ECPrivateKey, :ecPrivkeyVer1, seed, {:namedCurve, {1, 3, 101, 112}}, :asn1_NOVALUE,
         :asn1_NOVALUE}

      sig = :public_key.sign("", :none, priv)

      assert Base.encode16(sig, case: :upper) == @rfc_sig_hex

      assert :public_key.verify(
               "",
               :none,
               sig,
               {{:ECPoint, Base.decode16!(@rfc_pub_hex)}, {:namedCurve, {1, 3, 101, 112}}}
             )
    end

    test "v1a signs the canonical string, base64-prefixed, and verifies with the derived public key" do
      sig = Signing.sign_ed25519(@go_msg_id, @go_ts, @go_payload, @whsk)
      assert String.starts_with?(sig, "v1a,")

      assert {:ok, %{id: @go_msg_id, timestamp: @go_ts}} =
               Signing.verify(@go_payload, sw_headers(@go_msg_id, @go_ts, sig), @whpk,
                 ignore_timestamp: true
               )
    end

    test "whsk_ prefix is required and 32 decoded bytes enforced" do
      assert_raise ArgumentError, ~r/whsk_/, fn ->
        Signing.sign_ed25519(
          @go_msg_id,
          @go_ts,
          @go_payload,
          Base.encode64(Base.decode16!(@rfc_seed_hex))
        )
      end

      assert_raise ArgumentError, ~r/32/, fn ->
        Signing.sign_ed25519(
          @go_msg_id,
          @go_ts,
          @go_payload,
          "whsk_" <> Base.encode64(:crypto.strong_rand_bytes(31))
        )
      end
    end
  end

  describe "verify/4 — symmetric" do
    test "accepts the Go vector's headers (timestamp check bypassed for the 2021 vector)" do
      assert {:error, :timestamp_out_of_tolerance} =
               Signing.verify(@go_payload, sw_headers(@go_msg_id, @go_ts, @go_sig), @go_key,
                 now: @go_ts + 301
               )

      assert {:ok, %{id: @go_msg_id, timestamp: @go_ts}} =
               Signing.verify(@go_payload, sw_headers(@go_msg_id, @go_ts, @go_sig), @go_key,
                 now: @go_ts + 60
               )
    end

    test "accepts a current-timestamp signature under the default tolerance" do
      now = System.system_time(:second) - 30
      sig = Signing.sign(@go_msg_id, now, @go_payload, @go_key)
      assert {:ok, _} = Signing.verify(@go_payload, sw_headers(@go_msg_id, now, sig), @go_key)
    end

    test "rotation: the OLD secret's signature still verifies (multi-sig)" do
      old_key = "whsec_" <> Base.encode64(:binary.copy(<<1>>, 24))
      cur_sig = Signing.sign(@go_msg_id, @go_ts, @go_payload, @go_key)
      old_sig = Signing.sign(@go_msg_id, @go_ts, @go_payload, old_key)

      multi = cur_sig <> " " <> old_sig

      assert {:ok, _} =
               Signing.verify(@go_payload, sw_headers(@go_msg_id, @go_ts, multi), @go_key,
                 ignore_timestamp: true
               )

      assert {:ok, _} =
               Signing.verify(@go_payload, sw_headers(@go_msg_id, @go_ts, multi), old_key,
                 ignore_timestamp: true
               )
    end

    test "skips unknown version identifiers (v2, ...) like the references" do
      sig = Signing.sign(@go_msg_id, @go_ts, @go_payload, @go_key)
      multi = "v2," <> String.replace_prefix(sig, "v1,", "") <> " " <> sig

      assert {:ok, _} =
               Signing.verify(@go_payload, sw_headers(@go_msg_id, @go_ts, multi), @go_key,
                 ignore_timestamp: true
               )
    end

    test "rejects a payload whose FIRST byte was tampered" do
      sig = Signing.sign(@go_msg_id, @go_ts, @go_payload, @go_key)
      <<_first, rest::binary>> = @go_payload
      tampered = <<?x, rest::binary>>

      assert {:error, :invalid_signature} =
               Signing.verify(tampered, sw_headers(@go_msg_id, @go_ts, sig), @go_key,
                 ignore_timestamp: true
               )
    end

    test "rejects a signature whose first base64 char was tampered" do
      sig = Signing.sign(@go_msg_id, @go_ts, @go_payload, @go_key)
      <<_first, rest::binary>> = sig
      tampered = <<"W", rest::binary>>

      assert {:error, :invalid_signature} =
               Signing.verify(@go_payload, sw_headers(@go_msg_id, @go_ts, tampered), @go_key,
                 ignore_timestamp: true
               )
    end

    test "rejects truncated and empty signature entries" do
      for bad <- ["v1,", "v1", ""] do
        assert {:error, :invalid_signature} =
                 Signing.verify(@go_payload, sw_headers(@go_msg_id, @go_ts, bad), @go_key,
                   ignore_timestamp: true
                 )
      end
    end

    test "fails closed on an empty secret at verify" do
      assert {:error, :invalid_secret} =
               Signing.verify(@go_payload, sw_headers(@go_msg_id, @go_ts, @go_sig), "",
                 ignore_timestamp: true
               )
    end

    test "rejects missing headers individually" do
      for dropped <- ["webhook-id", "webhook-timestamp", "webhook-signature"] do
        headers = sw_headers(@go_msg_id, @go_ts, @go_sig) |> Map.delete(dropped)

        assert {:error, :missing_header} =
                 Signing.verify(@go_payload, headers, @go_key, ignore_timestamp: true)
      end
    end

    test "rejects malformed and out-of-tolerance timestamps" do
      assert {:error, :invalid_timestamp} =
               Signing.verify(
                 @go_payload,
                 sw_headers(@go_msg_id, @go_ts, @go_sig) |> Map.put("webhook-timestamp", "hello"),
                 @go_key
               )

      now = System.system_time(:second)

      for ts <- [now - 301, now + 301] do
        sig = Signing.sign(@go_msg_id, ts, @go_payload, @go_key)

        assert {:error, :timestamp_out_of_tolerance} =
                 Signing.verify(@go_payload, sw_headers(@go_msg_id, ts, sig), @go_key)

        assert {:ok, _} =
                 Signing.verify(@go_payload, sw_headers(@go_msg_id, ts, sig), @go_key,
                   ignore_timestamp: true
                 )
      end
    end
  end

  describe "verify/4 — asymmetric" do
    test "rejects a tampered payload under v1a" do
      sig = Signing.sign_ed25519(@go_msg_id, @go_ts, @go_payload, @whsk)
      <<_first, rest::binary>> = @go_payload
      tampered = <<?x, rest::binary>>

      assert {:error, :invalid_signature} =
               Signing.verify(tampered, sw_headers(@go_msg_id, @go_ts, sig), @whpk,
                 ignore_timestamp: true
               )
    end

    test "rejects the signature under a different public key" do
      sig = Signing.sign_ed25519(@go_msg_id, @go_ts, @go_payload, @whsk)

      wrong_pub =
        "whpk_" <>
          Base.encode64(
            :crypto.generate_key(:eddsa, :ed25519, :crypto.strong_rand_bytes(32))
            |> elem(0)
          )

      assert {:error, :invalid_signature} =
               Signing.verify(@go_payload, sw_headers(@go_msg_id, @go_ts, sig), wrong_pub,
                 ignore_timestamp: true
               )
    end

    test "a symmetric secret does not validate v1a entries (skipped like unknown versions)" do
      sig = Signing.sign_ed25519(@go_msg_id, @go_ts, @go_payload, @whsk)

      assert {:error, :invalid_signature} =
               Signing.verify(@go_payload, sw_headers(@go_msg_id, @go_ts, sig), @go_key,
                 ignore_timestamp: true
               )
    end
  end

  describe "headers and modes" do
    test "headers/4 emits exactly the three SW headers, v1+v1a joined by space" do
      v1 = Signing.sign(@go_msg_id, @go_ts, @go_payload, @go_key)
      v1a = Signing.sign_ed25519(@go_msg_id, @go_ts, @go_payload, @whsk)

      assert Signing.headers(@go_msg_id, @go_ts, @go_payload,
               whsec: @go_key,
               whsk: @whsk
             ) == %{
               "webhook-id" => @go_msg_id,
               "webhook-timestamp" => "1614265330",
               "webhook-signature" => v1 <> " " <> v1a
             }
    end

    test ":standard mode emits SW headers only" do
      headers =
        Signing.headers_for_mode(:standard, @go_msg_id, @go_ts, @go_payload, whsec: @go_key)

      assert Map.has_key?(headers, "webhook-signature")
      refute Map.has_key?(headers, "x-webhook-signature")
    end

    test ":legacy mode emits the incumbent envelope only" do
      headers =
        Signing.headers_for_mode(:legacy, @go_msg_id, @go_ts, @go_payload,
          legacy_secret: "legacy-incumbent-secret"
        )

      refute Map.has_key?(headers, "webhook-signature")
      assert Map.has_key?(headers, "x-webhook-signature")
    end

    test ":dual emits BOTH envelopes; requires the legacy secret" do
      headers =
        Signing.headers_for_mode(:dual, @go_msg_id, @go_ts, @go_payload,
          whsec: @go_key,
          legacy_secret: "legacy-incumbent-secret",
          legacy_previous_secret: "previous-secret"
        )

      assert Map.has_key?(headers, "webhook-signature")
      assert Map.has_key?(headers, "x-webhook-signature")

      assert_raise ArgumentError, ~r/legacy/, fn ->
        Signing.headers_for_mode(:dual, @go_msg_id, @go_ts, @go_payload, whsec: @go_key)
      end
    end
  end

  describe "secret and id generation" do
    test "generate_secret/1 yields a whsec_-prefixed 24-64 byte secret that signs+verifies" do
      secret = Signing.generate_secret()
      assert String.starts_with?(secret, "whsec_")
      assert {:ok, decoded} = Base.decode64(String.replace_prefix(secret, "whsec_", ""))
      assert byte_size(decoded) in 24..64

      sig = Signing.sign(@go_msg_id, @go_ts, @go_payload, secret)

      assert {:ok, _} =
               Signing.verify(@go_payload, sw_headers(@go_msg_id, @go_ts, sig), secret,
                 ignore_timestamp: true
               )
    end

    test "generate_signing_keypair/0 yields a working whsk_/whpk_ pair" do
      {whsk, whpk} = Signing.generate_signing_keypair()
      sig = Signing.sign_ed25519(@go_msg_id, @go_ts, @go_payload, whsk)

      assert {:ok, _} =
               Signing.verify(@go_payload, sw_headers(@go_msg_id, @go_ts, sig), whpk,
                 ignore_timestamp: true
               )
    end

    test "generate_msg_id/0 yields msg_-prefixed, dot-free ids" do
      id = Signing.generate_msg_id()
      assert String.starts_with?(id, "msg_")
      refute String.contains?(id, ".")
    end
  end

  describe "constant-time compare tripwire (mutation-red gate)" do
    @source_path Path.expand("../../lib/ash_hooks/signing.ex", __DIR__)

    test "verify compares via :crypto.hash_equals/2, never a bare == on signature material" do
      ast = source_ast(@source_path)

      assert module_calls_constant_time_compare?(ast),
             "the module must compare signature material with :crypto.hash_equals/2"

      refute module_compares_material_with_bare_equality?(ast, [:sig_bytes, :signature, :expected]),
             "signature material must not be compared with ==/!=/===/!== directly"
    end

    test "the named mutation (:crypto.hash_equals -> ==) turns the tripwire red" do
      mutated = mutate_hash_equals_to_equals(source_ast(@source_path))
      refute module_calls_constant_time_compare?(mutated)
    end
  end
end
