defmodule AshHooks.Provider.SchemeTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias AshHooks.Provider.{Scheme, Signature}

  # RFC 4231 test case 1 and RFC 2202 test case 1.
  @key :binary.copy(<<11>>, 20)
  @vectors [
    sha1: "b617318655057264e28bc0b6fb378c8ef146be00",
    sha256: "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
    sha384:
      "afd03944d84895626b0825f4ab46907f15f9dadbe4101ec682aa034c7cebc59cfaea9ea9076ede7f4af152e8b2fa9cb6",
    sha512:
      "87aa7cdea5ef619d4ff0b4241a1d6cb02379f4e2ce4ec2787ad0b30545e17cde" <>
        "daa833b7d6b8a702038b274eaea3f4e4be9d914eeb61f1702e696c203a126854"
  ]

  for {digest, hex} <- @vectors do
    test "RFC HMAC #{digest} known answer, encoding and key rotation" do
      digest = unquote(digest)
      hex = unquote(hex)
      bytes = Base.decode16!(hex, case: :lower)

      for {encoding, signature} <- [
            hex: hex,
            hex_upper: String.upcase(hex),
            hex_any: String.upcase(hex),
            raw: bytes,
            base64: Base.encode64(bytes),
            base64: Base.encode64(bytes, padding: false),
            base64url: Base.url_encode64(bytes),
            base64url: Base.url_encode64(bytes, padding: false)
          ] do
        opts = [digest: digest, encoding: encoding]
        assert :ok = Signature.hmac("Hi There", signature, ["wrong", "", @key], opts)
        assert {:error, :invalid_signature} = Signature.hmac("Hi There!", signature, @key, opts)
      end

      assert {:error, :invalid_signature} =
               Signature.hmac("Hi There", String.upcase(hex), @key, digest: digest)

      assert {:error, :no_webhook_secret} = Signature.hmac("Hi There", hex, ["", ""], [])
    end
  end

  test "public primitives reject arbitrary inputs without raising" do
    for value <- [nil, 12, :bad, %{}, [], [1 | 2], <<255>>] do
      assert {:error, _} = Signature.hmac(value, value, value, value)
      assert {:error, _} = Signature.rsa(value, value, value, value)
      assert {:error, _} = Signature.ecdsa(value, value, value, value)
      assert {:error, _} = Signature.ed25519(value, value, value, value)
      assert {:error, _} = Signature.jws(value, value, value)
    end

    assert {:error, :invalid_signature} = Signature.hmac("body", "!", "key", encoding: :bogus)
    assert {:error, :invalid_signature} = Signature.hmac("body", "a", "key", digest: :md5)
    assert :ok = Signature.compare("", "")
    assert {:error, :invalid_signature} = Signature.compare(nil, "")
    assert {:error, :invalid_signature} = Signature.compare("a", "bb")
    assert Signature.header(%{headers: %{nil => "x", "X-Sig" => "a"}}, "x-sig") == "a"
    assert Signature.header(nil, nil) == nil
    assert Signature.header(%{headers: %URI{}}, "x") == nil
    assert Signature.header(%{headers: %{"x" => 1}}, "x") == nil
  end

  test "timestamps accept Unix integers and ASCII digits with symmetric inclusive windows" do
    for timestamp <- [1_700_000_000, "1700000000"] do
      for offset <- [-300, 0, 300] do
        assert :ok =
                 Signature.check_timestamp(
                   timestamp,
                   %{now_ms: (1_700_000_000 + offset) * 1000},
                   300
                 )
      end

      assert {:error, :stale_timestamp} =
               Signature.check_timestamp(timestamp, %{now_ms: 1_700_000_301_000}, 300)
    end

    assert :ok = Signature.check_timestamp(System.system_time(:second), %{}, 300)

    for timestamp <- [-1, "-1", " 1", "+1", "1.0", "", "١", <<255>>, nil] do
      assert {:error, :invalid_signature} = Signature.check_timestamp(timestamp, %{}, 300)
    end

    assert {:error, :invalid_signature} = Signature.check_timestamp(1, %{now_ms: "bad"}, 300)
    assert {:error, :invalid_signature} = Signature.check_timestamp(1, %{}, 0)
  end

  test "RSA PKCS1 and PSS verify each digest, rotation, PEM and pinned certificate containers" do
    private = private_key()
    public = {:RSAPublicKey, elem(private, 2), elem(private, 3)}
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPublicKey, public)])
    cert = File.read!("test/fixtures/tls/server-both-san.pem")
    {spki, 0} = System.cmd("openssl", ["pkey", "-in", "test/fixtures/tls/server.key", "-pubout"])

    for digest <- [:sha256, :sha384, :sha512], padding <- [:pkcs1_v1_5, :pss] do
      options = rsa_options(padding, digest)
      signature = :public_key.sign("body", digest, private, options) |> Base.encode64()

      for key <- [public, pem, spki, cert, ["bad key", public]] do
        assert :ok = Signature.rsa("body", signature, key, digest: digest, padding: padding)

        assert {:error, :invalid_signature} =
                 Signature.rsa("changed", signature, key, digest: digest, padding: padding)
      end

      assert {:error, :invalid_signature} = Signature.rsa("body", signature, pem <> pem, [])
    end

    assert {:error, :no_webhook_secret} = Signature.rsa("body", "bad", [], [])
    assert {:error, :invalid_signature} = Signature.rsa("body", "bad", pem, padding: :bad)
    assert {:error, :invalid_signature} = Signature.rsa("body", "bad", pem, digest: :sha1)
  end

  test "ECDSA P256 and P384 support DER and fixed width P1363 with PEM keys" do
    for {curve, width} <- [{{1, 2, 840, 10_045, 3, 1, 7}, 32}, {{1, 3, 132, 0, 34}, 48}] do
      private = :public_key.generate_key({:namedCurve, curve})
      public = {{:ECPoint, elem(private, 4)}, {:namedCurve, curve}}
      pem = :public_key.pem_encode([:public_key.pem_entry_encode(:SubjectPublicKeyInfo, public)])

      for digest <- [:sha256, :sha384, :sha512] do
        der = :public_key.sign("body", digest, private)
        {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
        raw = <<r::unsigned-big-size(width * 8), s::unsigned-big-size(width * 8)>>

        for key <- [public, pem], {format, bytes} <- [der: der, raw: raw] do
          assert :ok =
                   Signature.ecdsa("body", Base.encode64(bytes), key,
                     digest: digest,
                     format: format
                   )

          assert {:error, :invalid_signature} =
                   Signature.ecdsa("changed", Base.encode64(bytes), key,
                     digest: digest,
                     format: format
                   )
        end

        assert {:error, :invalid_signature} =
                 Signature.ecdsa("body", Base.encode64(raw <> "x"), public, format: :raw)
      end
    end

    unsupported = :public_key.generate_key({:namedCurve, {1, 3, 132, 0, 35}})
    key = {{:ECPoint, elem(unsupported, 4)}, elem(unsupported, 3)}
    assert {:error, :invalid_signature} = Signature.ecdsa("body", "bad", key, [])
    assert {:error, :invalid_signature} = Signature.ecdsa("body", "bad", private_key(), [])
  end

  test "Ed25519 RFC 8032 empty-message known answer and key containers" do
    # https://www.rfc-editor.org/rfc/rfc8032#section-7.1
    key =
      Base.decode16!("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
        case: :lower
      )

    sig =
      Base.decode16!(
        "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555f" <>
          "b8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
        case: :lower
      )

    term = {{:ECPoint, key}, {:namedCurve, {1, 3, 101, 112}}}
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:SubjectPublicKeyInfo, term)])

    for public <- [key, term, pem] do
      assert :ok = Signature.ed25519("", Base.encode64(sig), public, [])
      assert {:error, :invalid_signature} = Signature.ed25519("x", Base.encode64(sig), public, [])
    end

    assert {:error, :invalid_signature} = Signature.ed25519("", Base.encode64(sig), <<1>>, [])

    assert {:error, :invalid_signature} =
             Signature.ed25519("", Base.encode64(sig), {:RSAPublicKey, 1, 3}, [])
  end

  test "JWS pins every supported algorithm and checks time only after authentication" do
    rsa = private_key()
    rsa_public = {:RSAPublicKey, elem(rsa, 2), elem(rsa, 3)}
    {ed, seed} = :crypto.generate_key(:eddsa, :ed25519)

    for {alg, digest} <- [
          {"HS256", :sha256},
          {"HS384", :sha384},
          {"HS512", :sha512},
          {"RS256", :sha256},
          {"RS384", :sha384},
          {"RS512", :sha512},
          {"PS256", :sha256},
          {"PS384", :sha384},
          {"PS512", :sha512},
          {"ES256", :sha256},
          {"ES384", :sha384},
          {"EdDSA", :none}
        ] do
      {key, signer} = jws_signer(alg, digest, rsa, rsa_public, ed, seed)

      token =
        token(
          %{"alg" => alg, "kid" => "ignored", "jku" => "https://invalid.example"},
          %{"exp" => 101, "nbf" => 100},
          signer
        )

      assert {:ok, ~s({"exp":101,"nbf":100})} =
               Signature.jws(token, key, alg: alg, now_ms: 100_000)

      assert {:error, :stale_timestamp} = Signature.jws(token, key, alg: alg, now_ms: 101_000)
      assert {:error, :stale_timestamp} = Signature.jws(token, key, alg: alg, now_ms: 99_000)

      assert {:error, :invalid_signature} =
               Signature.jws(token <> "x", key, alg: alg, now_ms: 200_000)

      assert {:error, :invalid_signature} = Signature.jws(token, key, alg: "none")
    end
  end

  test "JWS rejects malformed envelopes, header extensions, and nonnumeric claims" do
    signer = &:crypto.mac(:hmac, :sha256, "key", &1)

    for header <- [
          %{"alg" => "none"},
          %{"alg" => "HS384"},
          %{"alg" => "HS256", "crit" => ["x"]},
          %{"alg" => "HS256", "b64" => false}
        ] do
      assert {:error, :invalid_signature} =
               Signature.jws(token(header, %{}, signer), "key", alg: "HS256")
    end

    for claims <- [%{"exp" => "later"}, %{"nbf" => nil}] do
      assert {:error, :invalid_signature} =
               Signature.jws(token(%{"alg" => "HS256"}, claims, signer), "key", alg: "HS256")
    end

    assert {:ok, "[]"} =
             Signature.jws(token(%{"alg" => "HS256"}, [], signer), "key", alg: "HS256")

    for bad <- ["", "a.b", "a.b.c.d", "a.b.c", <<255>>] do
      assert {:error, :invalid_signature} = Signature.jws(bad, "key", alg: "HS256")
    end

    assert {:error, :invalid_signature} = Signature.jws("a.b.c", "key", [])
  end

  test "configured schemes extract candidates and authenticate before rejecting stale timestamps" do
    opts = [
      algorithm: :hmac_sha256,
      signature: {:structured_header, "x-sig", signature_key: "v1"},
      signed_input: [:timestamp, ".", :body],
      timestamp: {:signature_field, "t"}
    ]

    sig = :crypto.mac(:hmac, :sha256, "key", "100.body") |> Base.encode16(case: :lower)
    ctx = %{headers: %{"X-Sig" => "t=100,v1=bad,v1=" <> sig}, now_ms: 100_000}
    scheme = Scheme.new!(opts)
    assert :ok = Scheme.verify("body", ctx, ["wrong", "key"], scheme)
    assert Scheme.timestamp_header(scheme) == "x-sig"
    assert Scheme.signature_source(scheme) == :request

    assert {:error, :stale_timestamp} =
             Scheme.verify("body", %{ctx | now_ms: 401_000}, "key", opts)

    assert {:error, :invalid_signature} =
             Scheme.verify("changed", %{ctx | now_ms: 401_000}, "key", opts)

    assert :ok =
             Scheme.verify(
               "body",
               Map.put(%{ctx | now_ms: 401_000}, :replay_window_seconds, 302),
               "key",
               opts
             )

    assert {:error, :invalid_signature} =
             Scheme.verify(
               "body",
               %{
                 ctx
                 | headers: %{
                     "x-sig" => "t=100," <> Enum.map_join(1..17, ",", fn _ -> "v1=" <> sig end)
                   }
               },
               "key",
               opts
             )

    assert {:error, :invalid_signature} =
             Scheme.verify(
               "body",
               %{ctx | headers: %{"x-sig" => "t=100,v0=" <> sig}},
               "key",
               opts
             )

    assert {:error, :invalid_signature} =
             Scheme.verify(
               "body",
               %{ctx | headers: %{"x-sig" => "t=100,t=100,v1=" <> sig}},
               "key",
               opts
             )
  end

  test "scheme validates options and combinations with specific messages" do
    base = [algorithm: :hmac_sha256, signature: {:header, "x-sig"}]

    for {opts, pattern} <- [
          {[], ~r/algorithm/},
          {[algorithm: :unknown], ~r/algorithm/},
          {[algorithm: :hmac_sha256], ~r/signature/},
          {base ++ [unknown: true], ~r/unknown/},
          {base ++ [encoding: :raw], ~r/encoding/},
          {base ++ [key_encoding: :bad], ~r/key_encoding/},
          {base ++ [key_prefix: 1], ~r/key_prefix/},
          {base ++ [timestamp_unit: :bad], ~r/timestamp_unit/},
          {base ++ [tolerance_seconds: 0], ~r/tolerance_seconds/},
          {base ++ [ecdsa_format: :raw], ~r/ecdsa_format/},
          {base ++ [signed_input: []], ~r/signed_input/},
          {base ++ [signed_input: [:timestamp]], ~r/timestamp/},
          {base ++ [signed_input: [:bad]], ~r/signed_input/},
          {base ++ [timestamp: {:signature_field, "t"}], ~r/structured_header/},
          {[algorithm: :hmac_sha1, signature: :jws_body], ~r/jws_body/},
          {[algorithm: :hmac_sha256, signature: :jws_body, encoding: :hex], ~r/encoding/},
          {[algorithm: :hmac_sha256, signature: :jws_body, signed_input: :body],
           ~r/signed_input/},
          {[algorithm: :hmac_sha256, signature: :jws_body, timestamp: {:header, "t"}],
           ~r/timestamp/},
          {[algorithm: :hmac_sha256, signature: {:structured_header, "x", []}], ~r/signature_key/}
        ] do
      assert_raise ArgumentError, pattern, fn -> Scheme.new!(opts) end
    end

    assert_raise ArgumentError, ~r/options/, fn -> Scheme.new!(:bad) end

    assert_raise ArgumentError, ~r/algorithm/, fn ->
      Code.compile_string(
        "defmodule BadScheme#{System.unique_integer([:positive])} do use AshHooks.Provider, verify: [algorithm: :bad, signature: {:header, \"x\"}] end"
      )
    end
  end

  test "option validation rejects malformed nested values and duplicate keys" do
    base = [algorithm: :hmac_sha256, signature: {:header, "sig"}]

    for {option, value, pattern} <- [
          {:signature, {:header, ""}, ~r/header name/},
          {:signature, {:header, "sig", prefix: nil}, ~r/prefix/},
          {:signature, {:header, "sig", bad: true}, ~r/unknown.*header/},
          {:signature, {:header, "sig", [:bad]}, ~r/keyword/},
          {:signature, {:structured_header, "sig", signature_key: "v1", pair_separator: ""},
           ~r/pair_separator/},
          {:signature, {:structured_header, "sig", signature_key: "v1", key_value_separator: ""},
           ~r/key_value_separator/},
          {:signature, {:structured_header, "", signature_key: "v1"}, ~r/name/},
          {:timestamp, {:header, ""}, ~r/timestamp header/},
          {:timestamp, 42, ~r/timestamp/},
          {:signed_input, fn _ -> "body" end, ~r/signed_input/},
          {:signed_input, [{:header, ""}], ~r/signed_input/},
          {:signed_input, [{:base64, :unknown}], ~r/signed_input/}
        ] do
      assert_raise ArgumentError, pattern, fn -> Scheme.new!(Keyword.put(base, option, value)) end
    end

    assert_raise ArgumentError, ~r/duplicate/, fn ->
      Scheme.new!(base ++ [algorithm: :hmac_sha256])
    end

    assert_raise ArgumentError, ~r/duplicate/, fn ->
      Scheme.new!(Keyword.put(base, :signature, {:header, "sig", [prefix: "a", prefix: "b"]}))
    end

    assert_raise ArgumentError, ~r/signature_field key/, fn ->
      Scheme.new!(
        algorithm: :hmac_sha256,
        signature: {:structured_header, "sig", signature_key: "v1"},
        timestamp: {:signature_field, ""}
      )
    end

    assert_raise ArgumentError, ~r/ecdsa_format/, fn ->
      Scheme.new!(algorithm: :ecdsa_p256_sha256, signature: {:header, "sig"}, ecdsa_format: :bad)
    end

    assert_raise ArgumentError, ~r/ecdsa_format/, fn ->
      Scheme.new!(algorithm: :ecdsa_p256_sha256, signature: :jws_body, ecdsa_format: :raw)
    end

    assert_raise ArgumentError, ~r/timestamp_unit/, fn ->
      Scheme.new!(algorithm: :hmac_sha256, signature: :jws_body, timestamp_unit: :seconds)
    end
  end

  test "JWS accepts only host-function timestamp options and timestamp input parts require raw text" do
    base = [algorithm: :hmac_sha256, signature: :jws_body]

    for opts <- [[timestamp: nil], [tolerance_seconds: 10]] do
      assert_raise ArgumentError, ~r/timestamp/, fn -> Scheme.new!(base ++ opts) end
    end

    for part <- [:timestamp, {:base64, :timestamp}] do
      assert_raise ArgumentError, ~r/timestamp/, fn ->
        Scheme.new!(
          algorithm: :hmac_sha256,
          signature: {:header, "sig"},
          timestamp: fn _, _ -> {:ok, 1} end,
          signed_input: [part]
        )
      end
    end
  end

  test "PSS rejects a different MGF1 digest or salt length even with a real RSA signature" do
    private = private_key()
    public = {:RSAPublicKey, elem(private, 2), elem(private, 3)}

    for options <- [
          [rsa_padding: :rsa_pkcs1_pss_padding, rsa_mgf1_md: :sha256, rsa_pss_saltlen: 0],
          [rsa_padding: :rsa_pkcs1_pss_padding, rsa_mgf1_md: :sha384, rsa_pss_saltlen: 32]
        ] do
      signature = :public_key.sign("body", :sha256, private, options) |> Base.encode64()

      assert {:error, :invalid_signature} =
               Signature.rsa("body", signature, public, padding: :pss)
    end
  end

  test "use supports anonymous callbacks, remote captures, tuples and overridable defaults" do
    for canonical <- [
          "fn body, _ctx -> body end",
          "&AshHooks.Provider.SchemeTest.canonical/2",
          "{AshHooks.Provider.SchemeTest, :canonical}"
        ] do
      module = Module.concat(__MODULE__, "Generated#{System.unique_integer([:positive])}")

      Code.compile_string(
        "defmodule #{inspect(module)} do use AshHooks.Provider, verify: [algorithm: :hmac_sha256, signature: {:header, \"x\"}, signed_input: #{canonical}] end"
      )

      sig = :crypto.mac(:hmac, :sha256, "key", "body") |> Base.encode16(case: :lower)
      assert :ok = module.verify_signature("body", %{headers: %{"x" => sig}}, "key")
      assert module.timestamp_header() == nil
      assert module.signature_source() == :request
      assert {:ok, :webhook} = module.parse_event_type([])
      assert {:ok, %AshHooks.Provider.Event{}} = module.handle_event(:webhook, %{})
      assert {:error, :no_webhook_secret} = module.webhook_signing_secret(nil, nil)
      refute function_exported?(module, :decode_payload, 1)
    end
  end

  test "all configured algorithms and their JWS variants use the real primitive" do
    rsa = private_key()
    public = {:RSAPublicKey, elem(rsa, 2), elem(rsa, 3)}
    {ed, seed} = :crypto.generate_key(:eddsa, :ed25519)

    for {algorithm, alg, digest} <- [
          {:hmac_sha256, "HS256", :sha256},
          {:hmac_sha384, "HS384", :sha384},
          {:hmac_sha512, "HS512", :sha512},
          {:rsa_pkcs1_sha256, "RS256", :sha256},
          {:rsa_pkcs1_sha384, "RS384", :sha384},
          {:rsa_pkcs1_sha512, "RS512", :sha512},
          {:rsa_pss_sha256, "PS256", :sha256},
          {:rsa_pss_sha384, "PS384", :sha384},
          {:rsa_pss_sha512, "PS512", :sha512},
          {:ecdsa_p256_sha256, "ES256", :sha256},
          {:ecdsa_p384_sha384, "ES384", :sha384},
          {:ed25519, "EdDSA", :none}
        ] do
      {key, signer} = jws_signer(alg, digest, rsa, public, ed, seed)
      signature = signer.("body")

      {encoded, options} =
        case alg do
          "HS" <> _ -> {Base.encode16(signature, case: :lower), []}
          "ES" <> _ -> {Base.encode64(signature), [ecdsa_format: :raw]}
          _ -> {Base.encode64(signature), []}
        end

      opts = [algorithm: algorithm, signature: {:header, "sig"}] ++ options
      assert :ok = Scheme.verify("body", %{headers: %{"sig" => encoded}}, key, opts)

      assert {:error, :invalid_signature} =
               Scheme.verify("changed", %{headers: %{"sig" => encoded}}, key, opts)

      jws = token(%{"alg" => alg}, [], signer)
      assert :ok = Scheme.verify(jws, %{}, key, algorithm: algorithm, signature: :jws_body)
    end
  end

  test "ECDSA configured and JWS algorithms reject a key on the other supported curve" do
    private = :public_key.generate_key({:namedCurve, {1, 3, 132, 0, 34}})
    public = {{:ECPoint, elem(private, 4)}, elem(private, 3)}
    der = :public_key.sign("body", :sha256, private)
    assert :ok = Signature.ecdsa("body", Base.encode64(der), public, [])

    assert {:error, :invalid_signature} =
             Scheme.verify("body", %{headers: %{"sig" => Base.encode64(der)}}, public,
               algorithm: :ecdsa_p256_sha256,
               signature: {:header, "sig"}
             )

    signer = fn input ->
      {:"ECDSA-Sig-Value", r, s} =
        :public_key.der_decode(:"ECDSA-Sig-Value", :public_key.sign(input, :sha256, private))

      <<r::unsigned-big-size(384), s::unsigned-big-size(384)>>
    end

    assert {:error, :invalid_signature} =
             Signature.jws(token(%{"alg" => "ES256"}, %{}, signer), public, alg: "ES256")
  end

  test "key decoding accepts trusted encodings and optional prefixes and contains malformed keys" do
    body = "body"
    mac = :crypto.mac(:hmac, :sha256, "key", body) |> Base.encode16(case: :lower)
    base = [algorithm: :hmac_sha256, signature: {:header, "sig"}]
    ctx = %{headers: %{"sig" => mac}}

    for {encoding, encoded} <- [raw: "key", hex: "6B6579", base64: "a2V5", base64url: "a2V5"] do
      for key <- [encoded, "prefix_" <> encoded] do
        assert :ok =
                 Scheme.verify(
                   body,
                   ctx,
                   key,
                   base ++ [key_encoding: encoding, key_prefix: "prefix_"]
                 )
      end
    end

    for key <- ["!", <<255>>] do
      assert {:error, :invalid_signature} =
               Scheme.verify(body, ctx, key, base ++ [key_encoding: :base64])
    end

    assert {:error, :no_webhook_secret} =
             Scheme.verify(body, ctx, ["", "prefix_"], base ++ [key_prefix: "prefix_"])

    assert {:error, :invalid_signature} = Scheme.verify(body, ctx, {:RSAPublicKey, 1, 3}, base)
    assert_raise ArgumentError, fn -> Scheme.verify(body, ctx, "key", %{}) end
    assert_raise ArgumentError, fn -> Scheme.verify(body, ctx, "key", URI.parse("x")) end
    assert {:error, :invalid_signature} = Scheme.verify(nil, ctx, "key", base)
    assert {:error, :invalid_signature} = Scheme.verify(body, nil, "key", base)
    assert {:error, :invalid_signature} = Signature.hmac(body, mac, [107, 101, 121], [])
    assert :ok = Signature.hmac(body, mac, [nil, "key"], [])
  end

  test "signed-input parts preserve exact bytes and missing context always fails" do
    parts = [:method, ":", :url, ":", :path, ":", {:header, "X-Extra"}, ":", {:base64, :body}]
    input = "POST:https://example.com/a%2Fb?q=1:/a%2Fb: value :Ym9keQ=="
    signature = :crypto.mac(:hmac, :sha256, "key", input) |> Base.encode16(case: :lower)

    ctx = %{
      method: "POST",
      request_uri: "https://example.com/a%2Fb?q=1",
      headers: %{"x-extra" => " value ", "sig" => signature}
    }

    opts = [algorithm: :hmac_sha256, signature: {:header, "sig"}, signed_input: parts]
    assert :ok = Scheme.verify("body", ctx, "key", opts)

    for context <- [
          Map.delete(ctx, :method),
          Map.delete(ctx, :request_uri),
          %{ctx | headers: %{"sig" => signature}}
        ] do
      assert {:error, :invalid_signature} = Scheme.verify("body", context, "key", opts)
    end

    assert {:error, :invalid_signature} =
             Scheme.verify(
               "body",
               ctx,
               "key",
               Keyword.put(opts, :signed_input, [{:base64, {:header, "missing"}}])
             )

    for callback <- [
          fn _, _ -> nil end,
          fn _, _ -> raise "private" end,
          fn _, _ -> throw(:private) end,
          fn _, _ -> exit(:private) end
        ] do
      assert {:error, :invalid_signature} =
               Scheme.verify("body", ctx, "key", Keyword.put(opts, :signed_input, callback))
    end
  end

  test "header prefixes and structured fields fail closed and bound candidates inclusively" do
    mac = :crypto.mac(:hmac, :sha256, "key", "body") |> Base.encode16(case: :lower)
    opts = [algorithm: :hmac_sha256, signature: {:header, "sig", prefix: "sha256="}]
    assert :ok = Scheme.verify("body", %{headers: %{"SIG" => "SHA256=" <> mac}}, "key", opts)

    for signature <- [mac, "sha1=" <> mac, "", nil, <<255>>] do
      assert {:error, :invalid_signature} =
               Scheme.verify("body", %{headers: %{"sig" => signature}}, "key", opts)
    end

    structured = [
      algorithm: :hmac_sha256,
      signature: {:structured_header, "sig", signature_key: "v1"}
    ]

    assert {:error, :invalid_signature} = Scheme.verify("body", %{}, "key", structured)

    assert :ok =
             Scheme.verify(
               "body",
               %{
                 headers: %{
                   "sig" => "ignore, " <> Enum.map_join(1..16, ",", fn _ -> "v1=" <> mac end)
                 }
               },
               "key",
               structured
             )

    assert {:error, :invalid_signature} =
             Scheme.verify("body", %{headers: %{"sig" => "V1=" <> mac}}, "key", structured)
  end

  test "header, field, and function timestamps validate raw digit text after authentication" do
    mac = :crypto.mac(:hmac, :sha256, "key", "body") |> Base.encode16(case: :lower)
    ctx = %{headers: %{"sig" => mac, "t" => "100"}, now_ms: 100_000}
    base = [algorithm: :hmac_sha256, signature: {:header, "sig"}, timestamp: {:header, "t"}]
    assert :ok = Scheme.verify("body", ctx, "key", base)

    for text <- [nil, "", "+100", "-100", "100.0", " 100", "١", <<255>>] do
      assert {:error, :invalid_signature} =
               Scheme.verify(
                 "body",
                 %{ctx | headers: Map.put(ctx.headers, "t", text)},
                 "key",
                 base
               )
    end

    for function <- [fn _, _ -> {:ok, 100} end, {__MODULE__, :timestamp}] do
      scheme = Scheme.new!(Keyword.put(base, :timestamp, function))
      assert Scheme.timestamp_header(scheme) == nil
      assert :ok = Scheme.verify("body", ctx, "key", scheme)

      assert {:error, :stale_timestamp} =
               Scheme.verify("body", %{ctx | now_ms: 401_000}, "key", scheme)

      assert {:error, :invalid_signature} =
               Scheme.verify("body", ctx, "key", %{scheme | signed_input: [:timestamp]})
    end

    for function <- [fn _, _ -> :error end, fn _, _ -> {:ok, -1} end] do
      assert {:error, :invalid_signature} =
               Scheme.verify("body", ctx, "key", Keyword.put(base, :timestamp, function))
    end

    ms = Keyword.put(base, :timestamp_unit, :milliseconds)

    assert :ok =
             Scheme.verify(
               "body",
               %{ctx | headers: Map.put(ctx.headers, "t", "100999")},
               "key",
               ms
             )

    structured = [
      algorithm: :hmac_sha256,
      signature: {:structured_header, "sig", signature_key: "v1"},
      timestamp: {:signature_field, "t"}
    ]

    assert {:error, :invalid_signature} =
             Scheme.verify("body", %{ctx | headers: %{"sig" => "v1=" <> mac}}, "key", structured)
  end

  test "JWS payload decoding is explicit and accepts JSON objects and lists only" do
    scheme = Scheme.new!(algorithm: :hmac_sha256, signature: :jws_body)
    assert Scheme.signature_source(scheme) == :body

    for value <- [%{}, []] do
      jws = token(%{"alg" => "HS256"}, value, &:crypto.mac(:hmac, :sha256, "key", &1))
      assert {:ok, ^value} = Scheme.decode_payload(jws, scheme)
    end

    for body <- [nil, "a.b", "a.!.c", "a.b.c.d", "a.b.c", "a.bnVsbA.c"] do
      assert {:error, :malformed_payload} = Scheme.decode_payload(body, scheme)
    end

    assert {:error, :malformed_payload} =
             Scheme.decode_payload(
               "a.e30.c",
               Scheme.new!(algorithm: :hmac_sha256, signature: {:header, "sig"})
             )

    signer = &:crypto.mac(:hmac, :sha256, "key", &1)

    for alg <- ["none", "unsupported"] do
      assert {:error, :invalid_signature} =
               Signature.jws(token(%{"alg" => alg}, %{}, signer), "key", alg: alg)
    end

    assert {:error, :invalid_signature} = Signature.ecdsa("body", "bad", "key", format: :bad)
    assert {:error, :invalid_signature} = Signature.ed25519(nil, "bad", "key", [])
    assert {:error, :invalid_signature} = Signature.check_timestamp(1, :invalid, 1)
  end

  test "invalid key containers and public-key algorithm mismatches never raise" do
    for pem <- [
          "-----BEGIN PUBLIC KEY-----\nYQ==\n-----END PUBLIC KEY-----",
          File.read!("test/fixtures/tls/server.key"),
          "not a PEM"
        ] do
      assert {:error, :invalid_signature} = Signature.rsa("body", "AA==", pem, [])

      assert {:error, :invalid_signature} =
               Scheme.verify("body", %{headers: %{"sig" => "AA=="}}, pem,
                 algorithm: :rsa_pkcs1_sha256,
                 signature: {:header, "sig"}
               )
    end

    for algorithm <- ["EC", "ED25519", "ED448"] do
      {private, cert} = certificate(algorithm)
      digest = if algorithm == "EC", do: :sha256, else: :none
      signature = :public_key.sign("body", digest, private) |> Base.encode64()

      case algorithm do
        "EC" ->
          assert :ok = Signature.ecdsa("body", signature, cert, [])

        "ED25519" ->
          assert :ok = Signature.ed25519("body", signature, cert, [])

        "ED448" ->
          assert {:error, :invalid_signature} = Signature.ed25519("body", signature, cert, [])
      end

      assert {:error, :invalid_signature} = Signature.rsa("body", signature, cert, [])
    end
  end

  def timestamp(_, _), do: {:ok, 100}

  defp certificate(algorithm) do
    directory =
      Path.join(System.tmp_dir!(), "ash-hooks-key-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    key_path = Path.join(directory, "key.pem")
    options = if algorithm == "EC", do: ["-pkeyopt", "ec_paramgen_curve:prime256v1"], else: []

    {_, 0} =
      System.cmd("openssl", ["genpkey", "-algorithm", algorithm, "-out", key_path] ++ options,
        stderr_to_stdout: true
      )

    {pem, 0} =
      System.cmd(
        "openssl",
        ["req", "-new", "-x509", "-key", key_path, "-subj", "/CN=key-container", "-days", "1"],
        stderr_to_stdout: true
      )

    [entry] = :public_key.pem_decode(File.read!(key_path))
    {:public_key.pem_entry_decode(entry), pem}
  end

  test "a JWS provider supports an anonymous host timestamp and every generated callback is overridable" do
    module = Module.concat(__MODULE__, "Overrides#{System.unique_integer([:positive])}")

    Code.compile_string("""
    defmodule #{inspect(module)} do
      use AshHooks.Provider, verify: [algorithm: :hmac_sha256, signature: :jws_body,
        timestamp: fn _, _ -> {:ok, 100} end, tolerance_seconds: 1]
      @impl true
      def verify_signature(body, ctx, key), do: super(body, ctx, key)
      @impl true
      def timestamp_header, do: super()
      @impl true
      def signature_source, do: super()
      @impl true
      def parse_event_type(payload), do: super(payload)
      @impl true
      def handle_event(type, payload), do: super(type, payload)
      @impl true
      def decode_payload(body), do: super(body)
    end
    """)

    signer = &:crypto.mac(:hmac, :sha256, "key", &1)
    jws = token(%{"alg" => "HS256"}, %{}, signer)
    assert :ok = module.verify_signature(jws, %{now_ms: 100_000}, "key")
    assert {:error, :stale_timestamp} = module.verify_signature(jws, %{now_ms: 102_000}, "key")
    assert module.timestamp_header() == nil
    assert module.signature_source() == :body
    assert {:ok, :webhook} = module.parse_event_type(%{})
    assert {:ok, %AshHooks.Provider.Event{}} = module.handle_event(:webhook, %{})
    assert {:ok, %{}} = module.decode_payload(jws)
  end

  def canonical(body, _ctx), do: body

  defp private_key do
    [entry] = :public_key.pem_decode(File.read!("test/fixtures/tls/server.key"))
    :public_key.pem_entry_decode(entry)
  end

  defp rsa_options(:pkcs1_v1_5, _), do: []

  defp rsa_options(:pss, digest),
    do: [
      rsa_padding: :rsa_pkcs1_pss_padding,
      rsa_mgf1_md: digest,
      rsa_pss_saltlen: byte_size(:crypto.hash(digest, ""))
    ]

  defp token(header, claims, signer) do
    input =
      Base.url_encode64(Jason.encode!(header), padding: false) <>
        "." <> Base.url_encode64(Jason.encode!(claims), padding: false)

    input <> "." <> Base.url_encode64(signer.(input), padding: false)
  end

  defp jws_signer("HS" <> _, digest, _, _, _, _),
    do: {"key", &:crypto.mac(:hmac, digest, "key", &1)}

  defp jws_signer("RS" <> _, digest, private, public, _, _),
    do: {public, &:public_key.sign(&1, digest, private)}

  defp jws_signer("PS" <> _, digest, private, public, _, _),
    do: {public, &:public_key.sign(&1, digest, private, rsa_options(:pss, digest))}

  defp jws_signer("ES" <> size, digest, _, _, _, _) do
    {curve, width} =
      if size == "256", do: {{1, 2, 840, 10_045, 3, 1, 7}, 32}, else: {{1, 3, 132, 0, 34}, 48}

    private = :public_key.generate_key({:namedCurve, curve})
    public = {{:ECPoint, elem(private, 4)}, {:namedCurve, curve}}

    signer = fn input ->
      {:"ECDSA-Sig-Value", r, s} =
        :public_key.der_decode(:"ECDSA-Sig-Value", :public_key.sign(input, digest, private))

      <<r::unsigned-big-size(width * 8), s::unsigned-big-size(width * 8)>>
    end

    {public, signer}
  end

  defp jws_signer("EdDSA", _, _, _, public, seed),
    do: {public, &:crypto.sign(:eddsa, :none, &1, [seed, :ed25519])}

  test "header lookup reads ordered lists as well as maps and joins repeated lines" do
    list = [{"X-Sig", "a"}, {"other", "z"}, {"x-sig", "b"}, {:bad, "c"}, {"x-sig", :bad}]
    assert Signature.header(%{headers: list}, "x-SIG") == "a, b"
    assert Signature.header(%{headers: list}, "absent") == nil
    assert Signature.header(%{headers: %{"X-Sig" => "m"}}, "x-sig") == "m"

    scheme = [algorithm: :hmac_sha256, signature: {:header, "x-sig"}]
    mac = :crypto.mac(:hmac, :sha256, "key", "body") |> Base.encode16(case: :lower)

    assert :ok =
             Scheme.verify("body", %{headers: [{"X-Sig", mac}]}, "key", scheme)

    assert {:error, :invalid_signature} =
             Scheme.verify(
               "body",
               %{headers: [{"x-sig", mac}, {"x-sig", mac}]},
               "key",
               scheme
             )
  end

  test "primitive options default to their documented values" do
    mac = :crypto.mac(:hmac, :sha256, "key", "body") |> Base.encode16(case: :lower)
    assert :ok = Signature.hmac("body", mac, "key")

    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    signature = :crypto.sign(:eddsa, :none, "body", [private, :ed25519]) |> Base.encode64()
    assert :ok = Signature.ed25519("body", signature, public)

    rsa = :public_key.generate_key({:rsa, 2048, 65_537})
    {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} = rsa
    rsa_signature = :public_key.sign("body", :sha256, rsa) |> Base.encode64()
    assert :ok = Signature.rsa("body", rsa_signature, {:RSAPublicKey, n, e})

    ec = :public_key.generate_key({:namedCurve, {1, 2, 840, 10_045, 3, 1, 7}})
    {:ECPrivateKey, _, _, curve, point, _} = ec
    ec_signature = :public_key.sign("body", :sha256, ec) |> Base.encode64()
    assert :ok = Signature.ecdsa("body", ec_signature, {{:ECPoint, point}, curve})
  end

  test "direct verification raises on an invalid configuration instead of rejecting the request" do
    assert_raise ArgumentError, ~r/encoding must be/, fn ->
      Scheme.verify("body", %{headers: %{}}, "key",
        algorithm: :hmac_sha256,
        signature: {:header, "x-sig"},
        encoding: :hexadecimal
      )
    end
  end

  test "a plain use AshHooks.Provider module needs no @impl annotations" do
    name = "PlainProvider#{System.unique_integer([:positive])}"

    warnings =
      capture_io(:stderr, fn ->
        [{module, _}] =
          Code.compile_string("""
          defmodule AshHooks.Provider.SchemeTest.#{name} do
            use AshHooks.Provider
            def verify_signature(_body, _ctx, _secret), do: :ok
            def parse_event_type(_payload), do: {:ok, :webhook}
            def handle_event(type, payload), do: {:ok, %AshHooks.Provider.Event{type: type, payload: payload}}
          end
          """)

        :code.purge(module)
        :code.delete(module)
      end)

    refute warnings =~ "@impl"
  end

  test "JWS payload identity is canonical JSON, independent of key order" do
    assert {:ok, id} = Scheme.payload_identity(%{"b" => [1, %{"y" => 2, "x" => 1}], "a" => "z"})

    assert {:ok, ^id} =
             Scheme.payload_identity(Jason.decode!(~s({"a":"z","b":[1,{"x":1,"y":2}]})))

    assert id ==
             :crypto.hash(:sha256, ~s({"a":"z","b":[1,{"x":1,"y":2}]}))
             |> Base.encode16(case: :lower)

    refute {:ok, id} == Scheme.payload_identity(%{"a" => "z", "b" => [%{"x" => 1, "y" => 2}, 1]})
    assert {:error, :malformed_payload} = Scheme.payload_identity("token")
  end

  test "header lookup returns nil for an improper header list" do
    assert Signature.header(%{headers: [{"sig", "value"} | :improper]}, "sig") == nil
    assert Signature.header(%{headers: [:junk, {"sig", "value"}]}, "sig") == "value"
  end

  test "use accepts closures over private helpers and attribute values in place" do
    name = "ClosureProvider#{System.unique_integer([:positive])}"

    [{closure, _}] =
      Code.compile_string(
        """
        defmodule AshHooks.Provider.SchemeTest.#{name} do
          use AshHooks.Provider,
            verify: [
              algorithm: :hmac_sha256,
              signature: {:header, @sig},
              signed_input: fn body, ctx -> canonical(body, ctx) end
            ]

          defp canonical(body, _ctx), do: "v1:" <> body
        end
        """
        |> String.replace("@sig", ~s("x-sig"))
      )

    mac = :crypto.mac(:hmac, :sha256, "key", "v1:body") |> Base.encode16(case: :lower)
    assert :ok = closure.verify_signature("body", %{headers: %{"x-sig" => mac}}, "key")
    assert closure.signature_source() == :request
    assert closure.timestamp_header() == nil

    jws_name = "InPlaceJws#{System.unique_integer([:positive])}"

    [{jws, _}] =
      Code.compile_string("""
      defmodule AshHooks.Provider.SchemeTest.#{jws_name} do
        @ts "x-ts"
        use AshHooks.Provider,
          verify: [
            algorithm: :hmac_sha256,
            signature: :jws_body,
            timestamp: fn _body, ctx -> {:ok, String.to_integer(ctx.headers[@ts])} end
          ]
      end
      """)

    assert jws.signature_source() == :body
    assert jws.timestamp_header() == nil
    assert {:ok, _} = jws.event_identity(%{"a" => 1})

    for module <- [closure, jws] do
      :code.purge(module)
      :code.delete(module)
    end
  end

  test "use rejects options it cannot read and invalid options after compiling" do
    for {source, message} <- [
          {"use AshHooks.Provider, verify: options()", ~r/keyword list written in place/},
          {"use AshHooks.Provider, verify: [:hmac_sha256]",
           ~r/expects verify: to be a keyword list/},
          {"@verify [algorithm: :hmac_sha256]\n  use AshHooks.Provider, verify: @verify",
           ~r/keyword list written in place/},
          {"use AshHooks.Provider, verify: [algorithm: :hmac_md5, signature: {:header, \"x\"}]",
           ~r/algorithm must be one of/}
        ] do
      name = "Rejected#{System.unique_integer([:positive])}"

      assert_raise ArgumentError, message, fn ->
        Code.compile_string("""
        defmodule AshHooks.Provider.SchemeTest.#{name} do
          #{source}
        end
        """)
      end
    end
  end
end
