defmodule AshHooks.Provider.HmacTest do
  use ExUnit.Case, async: true
  alias AshHooks.Provider.Hmac

  # RFC 4231 test 1 (SHA256), RFC 2202 test 1 (SHA1), published known answers.
  @body "Hi There"
  @key :binary.copy(<<11>>, 20)
  @sha256 "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
  @sha1 "b617318655057264e28bc0b6fb378c8ef146be00"

  test "RFC SHA256 vector with a configured case-insensitive header and overlap keys" do
    ctx = %{headers: %{"X-Emitter-Signature" => @sha256}, signature: "ignored"}
    opts = [header: "x-emitter-signature", algorithm: :sha256, encoding: :hex]
    assert :ok = Hmac.verify_signature(@body, ctx, "new-key", opts ++ [previous_secrets: [@key]])
    assert {:error, :invalid_signature} = Hmac.verify_signature(@body <> "!", ctx, @key, opts)

    assert {:error, :invalid_signature} =
             Hmac.verify_signature(@body, %{ctx | headers: %{}}, @key, opts)

    assert {:error, :no_webhook_secret} = Hmac.verify_signature(@body, ctx, "", opts)
  end

  test "RFC SHA1 vectors support hex and base64 without algorithm guessing" do
    assert :ok =
             Hmac.verify_signature(@body, %{signature: @sha1}, @key,
               algorithm: :sha1,
               encoding: :hex
             )

    signature = @sha1 |> Base.decode16!(case: :lower) |> Base.encode64()

    assert :ok =
             Hmac.verify_signature(@body, %{signature: signature}, ["new-key", @key],
               algorithm: :sha1,
               encoding: :base64
             )

    assert {:error, :invalid_signature} =
             Hmac.verify_signature(@body, %{signature: @sha1}, @key, algorithm: :sha256)
  end

  test "an optional timestamp is signed with the body and checked against tolerance" do
    body = ~s({"id":"evt_1","type":"order.created"})

    ctx = %{
      headers: %{
        "x-time" => "1700000000",
        "x-sig" => "14852ee51817599372538c265e8d14af52a5c81c9a7daa1424f386b1b0bb5913"
      },
      now_ms: 1_700_000_000_000
    }

    opts = [header: "x-sig", timestamp_header: "x-time", tolerance_seconds: 60]
    assert :ok = Hmac.verify_signature(body, ctx, "test-key", opts)

    assert {:error, :stale_timestamp} =
             Hmac.verify_signature(body, %{ctx | now_ms: ctx.now_ms + 61_000}, "test-key", opts)

    assert {:error, :invalid_signature} =
             Hmac.verify_signature(
               body,
               %{ctx | headers: Map.put(ctx.headers, "x-time", "1700000001")},
               "test-key",
               opts
             )

    assert {:error, :invalid_signature} =
             Hmac.verify_signature(
               body,
               %{ctx | headers: Map.delete(ctx.headers, "x-time")},
               "test-key",
               opts
             )
  end

  test "a host canonicalizer owns its exact signing input and malformed configuration fails closed" do
    ctx = %{signature: @sha256}
    canonical = fn _raw, _ctx -> @body end

    assert :ok =
             Hmac.verify_signature("host wire representation", ctx, @key,
               canonical_input: canonical
             )

    assert :ok =
             Hmac.verify_signature("host wire representation", ctx, @key,
               canonical_input: {__MODULE__, :canonical}
             )

    for opts <- [
          [algorithm: :md5],
          [encoding: :unknown],
          [canonical_input: fn _, _ -> nil end],
          [canonical_input: fn _, _ -> raise "private" end]
        ] do
      assert {:error, :invalid_signature} = Hmac.verify_signature(@body, ctx, @key, opts)
    end
  end

  test "SHA384 and SHA512 are plain algorithm values" do
    for digest <- [:sha384, :sha512] do
      signature = :crypto.mac(:hmac, digest, @key, @body) |> Base.encode16(case: :lower)
      assert :ok = Hmac.verify_signature(@body, %{signature: signature}, @key, algorithm: digest)
    end
  end

  def canonical(_body, _ctx), do: @body

  test "default verification rejects malformed headers, missing authenticated time, and thrown callbacks" do
    ctx = %{signature: @sha256}
    assert :ok = Hmac.verify_signature(@body, ctx, @key)

    for {context, opts} <- [
          {ctx, [header: "missing"]},
          {%{headers: %{"x-sig" => [@sha256]}}, [header: "x-sig"]},
          {ctx, [previous_secrets: :not_a_list]},
          {ctx, [canonical_input: 42]},
          {ctx, [canonical_input: fn _, _ -> throw(:private_callback_failure) end]},
          {ctx, [timestamp_header: "missing", canonical_input: {__MODULE__, :canonical}]}
        ] do
      assert {:error, :invalid_signature} = Hmac.verify_signature(@body, context, @key, opts)
    end
  end
end
