defmodule AshHooks.Provider.Signature do
  @moduledoc """
  Stateless webhook signature verification with caller-pinned keys and algorithms.

  HMAC, RSA, ECDSA and Ed25519 functions return `:ok`, `{:error, :invalid_signature}`
  or `{:error, :no_webhook_secret}`; `jws/3` and `check_timestamp/3` can also return
  `{:error, :stale_timestamp}`. `jws/3` returns the authenticated payload bytes. Malformed input never raises.

  `encoding:` describes the received signature: `:hex` is lowercase only,
  `:hex_upper` uppercase only, `:hex_any` accepts either case, `:base64` and
  `:base64url` accept padded or unpadded strings, and `:raw` accepts bytes.
  Keys may be a single key or a rotation list; empty keys cannot verify.
  HMAC accepts `AshHooks.Custody.Key` values, including rotation lists mixed
  with byte keys. It decodes signatures before custody verification and returns
  classified custody errors. A successful rotation key authenticates the request;
  otherwise configuration and availability errors take precedence over a MAC
  mismatch. Byte-only failures keep their existing atom results.
  HMAC evaluates all keys and compares bytes in constant time behind a length guard.

  Asymmetric keys may be decoded `:public_key` terms or a PEM containing exactly
  one PUBLIC KEY, RSA PUBLIC KEY, or CERTIFICATE. A certificate is only a public
  key container pinned by the host: chain, expiry, and revocation are not checked.
  Ed25519 also accepts a raw 32-byte public key. Key types must match the algorithm.
  Asymmetric verification never goes through custody: an `AshHooks.Custody.Key`
  in an RSA, ECDSA or Ed25519 key list returns
  `AshHooks.Errors.Invalid.KeyKindMismatch` unless another key verifies, ranked
  as HMAC ranks a rotation list.
  `AshHooks.Custody.PublicKey` pins an asymmetric algorithm, including its
  digest, padding and curve. HMAC refuses pinned public keys with
  `KeyKindMismatch`. Asymmetric verifiers preserve that classification when
  the pinned kind does not match their algorithm.
  Keys are never fetched from request headers, tokens, or URLs.
  """
  alias AshHooks.Custody
  alias AshHooks.Custody.Key, as: CustodyKey
  alias AshHooks.Custody.PublicKey
  alias AshHooks.Errors.Invalid.InvalidSignature
  alias AshHooks.Provider.Signature.Key

  @type error ::
          {:error,
           :invalid_signature
           | :no_webhook_secret
           | :stale_timestamp
           | :malformed_payload
           | struct()}
  @p256 {1, 2, 840, 10_045, 3, 1, 7}
  @p384 {1, 3, 132, 0, 34}

  @doc "Verifies HMAC; options: `digest:` (default `:sha256`, also `:sha1`, `:sha384`, `:sha512`) and `encoding:` (default `:hex`)."
  @spec hmac(binary(), binary(), term(), keyword()) :: :ok | error()
  def hmac(input, signature, keys, opts \\ []) do
    with {:ok, keys} <- Key.list(keys),
         true <- is_binary(input) and Keyword.keyword?(opts),
         digest when digest in [:sha1, :sha256, :sha384, :sha512] <-
           Keyword.get(opts, :digest, :sha256),
         {:ok, received} <- decode(signature, Keyword.get(opts, :encoding, :hex)) do
      keys
      |> Enum.map(&hmac_match(input, received, &1, digest))
      |> verification_result()
    else
      {:error, _} = error -> error
      _ -> invalid()
    end
  catch
    _, _ -> invalid()
  end

  defp hmac_match(input, received, key, digest) when is_binary(key),
    do:
      compare(
        :crypto.mac(:hmac, if(digest == :sha1, do: :sha, else: digest), key, input),
        received
      )

  defp hmac_match(input, received, %CustodyKey{kind: kind} = key, digest) do
    if kind in [{:sender_hmac, digest}, {:standard_webhooks, :v1}, {:legacy_hmac, :sha256}] and
         (elem(kind, 0) == :sender_hmac or digest == :sha256) do
      Custody.verify(key, input, received)
    else
      AshHooks.Errors.from_custody_result({:error, :kind_mismatch})
    end
  end

  defp hmac_match(_, _, %PublicKey{}, _),
    do: AshHooks.Errors.from_custody_result({:error, :kind_mismatch})

  defp hmac_match(_, _, _, _), do: invalid()

  @doc false
  def verification_result(results) do
    cond do
      :ok in results -> :ok
      error = Enum.find(results, &configuration_error?/1) -> error
      error = Enum.find(results, &match?({:error, %InvalidSignature{}}, &1)) -> error
      true -> invalid()
    end
  end

  defp configuration_error?({:error, :invalid_signature}), do: false
  defp configuration_error?({:error, %InvalidSignature{}}), do: false
  defp configuration_error?({:error, _}), do: true

  @doc """
  Verifies RSA; options: `digest:` (`:sha256` default, `:sha384`, `:sha512`),
  `padding:` (`:pkcs1_v1_5` default or `:pss`) and `encoding:` (`:base64` default).
  PSS pins MGF1 to the digest and salt length to its byte length (RFC 7518).
  """
  @spec rsa(binary(), binary(), term(), keyword()) :: :ok | error()
  def rsa(input, signature, keys, opts \\ []) do
    digest = Keyword.get(opts, :digest, :sha256)
    padding = Keyword.get(opts, :padding, :pkcs1_v1_5)

    if digest in [:sha256, :sha384, :sha512] and padding in [:pkcs1_v1_5, :pss] do
      asymmetric(input, signature, keys, opts, :rsa, {:rsa, digest, padding}, fn bytes, key ->
        :public_key.verify(input, digest, bytes, key, rsa_options(padding, digest))
      end)
    else
      invalid()
    end
  catch
    _, _ -> invalid()
  end

  defp rsa_options(:pkcs1_v1_5, _), do: [rsa_padding: :rsa_pkcs1_padding]

  defp rsa_options(:pss, digest),
    do: [
      rsa_padding: :rsa_pkcs1_pss_padding,
      rsa_mgf1_md: digest,
      rsa_pss_saltlen: byte_size(:crypto.hash(digest, ""))
    ]

  @doc """
  Verifies ECDSA on P-256 or P-384; options: `digest:` (`:sha256` default,
  `:sha384`, `:sha512`), `format:` (`:der` default or fixed-width `:raw` r || s),
  and `encoding:` (`:base64` default). Other curves and incorrect widths fail.
  """
  @spec ecdsa(binary(), binary(), term(), keyword()) :: :ok | error()
  def ecdsa(input, signature, keys, opts \\ []) do
    safely(fn -> verify_ecdsa(input, signature, keys, opts, :ecdsa) end)
  end

  @doc "Verifies Ed25519 with `encoding:` (default `:base64`)."
  @spec ed25519(binary(), binary(), term(), keyword()) :: :ok | error()
  def ed25519(input, signature, keys, opts \\ []) do
    safely(fn ->
      asymmetric(input, signature, keys, opts, :ed25519, {:ed25519, :none, nil}, fn bytes, key ->
        :public_key.verify(input, :none, bytes, key)
      end)
    end)
  end

  @doc """
  Verifies compact JWS and returns `{:ok, payload_bytes}`.

  `alg:` is required and must exactly match the protected header: HS256/384/512,
  RS256/384/512, PS256/384/512, ES256, ES384, or EdDSA. ES algorithms pin the
  curve and raw signature format. `none`, nonempty `crit`, and `b64: false` fail,
  as do padded segments (RFC 7515 encodes them without `=`).
  Key-location headers are ignored. JSON object `exp` and `nbf` claims must be
  numeric and are checked only after verification, against `now_ms:` or the clock.
  `json_decoder:` accepts a one-argument decoder for both the protected header
  and claims, defaulting to `Jason.decode/1`. A header it refuses is
  `{:error, :invalid_signature}`; a payload it does not decode to a JSON object
  is not claim-checked; invalid claim types remain `{:error, :invalid_signature}`.
  The authenticated payload is returned as bytes, so the caller's own decode
  decides whether it is acceptable.
  """
  @spec jws(binary(), term(), keyword()) :: {:ok, binary()} | error()
  def jws(token, keys, opts) do
    safely(fn ->
      with true <- is_binary(token) and Keyword.keyword?(opts),
           false <- String.contains?(token, "="),
           [header, payload, signature] <- :binary.split(token, ".", [:global]),
           {:ok, header_bytes} <- decode(header, :base64url),
           {:ok, payload_bytes} <- decode(payload, :base64url),
           {:ok, header_data} <- decode_header(header_bytes, opts),
           true <- header_data["alg"] == opts[:alg] and is_binary(opts[:alg]),
           true <-
             Map.get(header_data, "crit", []) == [] and Map.get(header_data, "b64", true) == true,
           :ok <- verify_jws(opts[:alg], header <> "." <> payload, signature, keys),
           :ok <- check_claims(payload_bytes, opts) do
        {:ok, payload_bytes}
      else
        {:error, _} = error -> error
        _ -> invalid()
      end
    end)
  end

  @doc "Compares binary values in constant time after checking equal lengths."
  def compare(expected, actual) when is_binary(expected) and is_binary(actual) do
    result(byte_size(expected) == byte_size(actual) and :crypto.hash_equals(expected, actual))
  end

  def compare(_, _), do: invalid()

  @doc """
  Looks up a request header case-insensitively in `ctx.headers`, a map or an
  ordered `{name, value}` list such as `conn.req_headers`. Repeated lines in a
  list are joined with `", "`. Returns `nil` when the header is absent.
  """
  def header(%{headers: headers}, name) when is_map(headers) and is_binary(name) do
    wanted = String.downcase(name, :ascii)

    Enum.find_value(:maps.to_list(headers), fn
      {key, value} when is_binary(key) and is_binary(value) ->
        if String.downcase(key, :ascii) == wanted, do: value

      _ ->
        nil
    end)
  end

  def header(%{headers: headers}, name) when is_list(headers) and is_binary(name),
    do: list_header(headers, String.downcase(name, :ascii), [])

  def header(_, _), do: nil

  defp list_header([], _wanted, []), do: nil
  defp list_header([], _wanted, values), do: values |> Enum.reverse() |> Enum.join(", ")

  defp list_header([{key, value} | rest], wanted, values)
       when is_binary(key) and is_binary(value) do
    if String.downcase(key, :ascii) == wanted,
      do: list_header(rest, wanted, [value | values]),
      else: list_header(rest, wanted, values)
  end

  defp list_header([_entry | rest], wanted, values), do: list_header(rest, wanted, values)
  defp list_header(_improper, _wanted, _values), do: nil

  @doc "Checks nonnegative Unix seconds (integer or ASCII digit string) within a symmetric positive tolerance."
  def check_timestamp(timestamp, ctx, tolerance_seconds) do
    with {:ok, seconds} <- seconds(timestamp),
         true <- is_integer(tolerance_seconds) and tolerance_seconds > 0,
         now_ms when is_integer(now_ms) <- ctx[:now_ms] || System.system_time(:millisecond) do
      if abs(div(now_ms, 1000) - seconds) <= tolerance_seconds,
        do: :ok,
        else: {:error, :stale_timestamp}
    else
      _ -> invalid()
    end
  catch
    _, _ -> invalid()
  end

  defp asymmetric(input, signature, keys, opts, type, algorithm, verifier) do
    with {:ok, keys} <- Key.list(keys),
         true <- is_binary(input) and Keyword.keyword?(opts),
         {:ok, bytes} <- decode(signature, Keyword.get(opts, :encoding, :base64)) do
      keys
      |> Enum.map(&asymmetric_match(&1, type, algorithm, bytes, verifier))
      |> verification_result()
    else
      {:error, _} = error -> error
      _ -> invalid()
    end
  end

  defp asymmetric_match(%CustodyKey{}, _type, _algorithm, _bytes, _verifier),
    do: AshHooks.Errors.from_custody_result({:error, :kind_mismatch})

  defp asymmetric_match(%PublicKey{} = key, _type, algorithm, bytes, verifier) do
    with {:ok, decoded} <- PublicKey.decode(key, algorithm),
         do: result(verifier.(bytes, decoded))
  catch
    _, _ -> invalid()
  end

  defp asymmetric_match(key, type, _algorithm, bytes, verifier) do
    with {:ok, key} <- Key.decode(key, type), do: result(verifier.(bytes, key))
  catch
    _, _ -> invalid()
  end

  defp verify_ecdsa(input, signature, keys, opts, type) do
    digest = Keyword.get(opts, :digest, :sha256)
    format = Keyword.get(opts, :format, :der)

    if digest in [:sha256, :sha384, :sha512] and format in [:der, :raw] do
      asymmetric(
        input,
        signature,
        keys,
        opts,
        type,
        {ecdsa_type(type, digest), digest, nil},
        fn bytes, key ->
          :public_key.verify(input, digest, ecdsa_der(bytes, key, format), key)
        end
      )
    else
      invalid()
    end
  end

  defp ecdsa_type(:ecdsa, :sha256), do: {:ecdsa, @p256}
  defp ecdsa_type(:ecdsa, :sha384), do: {:ecdsa, @p384}
  defp ecdsa_type(type, _digest), do: type

  defp ecdsa_der(bytes, _key, :der), do: bytes

  defp ecdsa_der(bytes, {{:ECPoint, _}, {:namedCurve, curve}}, :raw) do
    width = if curve == @p256, do: 32, else: 48
    <<r::unsigned-big-size(^width * 8), s::unsigned-big-size(^width * 8)>> = bytes
    :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
  end

  defp verify_jws("HS" <> size, input, signature, keys) when size in ["256", "384", "512"],
    do: hmac(input, signature, keys, digest: digest(size), encoding: :base64url)

  defp verify_jws("RS" <> size, input, signature, keys) when size in ["256", "384", "512"],
    do: rsa(input, signature, keys, digest: digest(size), encoding: :base64url)

  defp verify_jws("PS" <> size, input, signature, keys) when size in ["256", "384", "512"],
    do: rsa(input, signature, keys, digest: digest(size), padding: :pss, encoding: :base64url)

  defp verify_jws("ES" <> size, input, signature, keys) when size in ["256", "384"] do
    curve = if size == "256", do: @p256, else: @p384

    verify_ecdsa(
      input,
      signature,
      keys,
      [digest: digest(size), format: :raw, encoding: :base64url],
      {:ecdsa, curve}
    )
  end

  defp verify_jws("EdDSA", input, signature, keys),
    do: ed25519(input, signature, keys, encoding: :base64url)

  defp verify_jws(_, _, _, _), do: invalid()

  defp digest("256"), do: :sha256
  defp digest("384"), do: :sha384
  defp digest("512"), do: :sha512

  defp check_claims(payload, opts) do
    case decode_json(payload, opts) do
      {:ok, claims} when is_map(claims) ->
        now = (opts[:now_ms] || System.system_time(:millisecond)) / 1000

        with :ok <- check_time(Map.fetch(claims, "exp"), now, :exp),
             do: check_time(Map.fetch(claims, "nbf"), now, :nbf)

      _not_a_claims_object ->
        :ok
    end
  end

  # The protected header is read before verification: a header the decoder
  # refuses cannot be verified, so it is an invalid signature, never a
  # malformed payload.
  defp decode_header(bytes, opts) do
    case decode_json(bytes, opts) do
      {:ok, header} when is_map(header) -> {:ok, header}
      _refused -> :invalid_header
    end
  end

  defp decode_json(bytes, opts),
    do: AshHooks.Provider.decode_json(bytes, Keyword.get(opts, :json_decoder, &Jason.decode/1))

  defp check_time(:error, _, _), do: :ok
  defp check_time({:ok, time}, _, _) when not is_number(time), do: invalid()
  defp check_time({:ok, time}, now, :exp) when now >= time, do: {:error, :stale_timestamp}
  defp check_time({:ok, time}, now, :nbf) when now < time, do: {:error, :stale_timestamp}
  defp check_time(_, _, _), do: :ok

  defp seconds(timestamp) when is_integer(timestamp) and timestamp >= 0, do: {:ok, timestamp}

  defp seconds(timestamp) when is_binary(timestamp) do
    if timestamp != "" and Enum.all?(:binary.bin_to_list(timestamp), &(&1 in ?0..?9)),
      do: {:ok, String.to_integer(timestamp)},
      else: invalid()
  end

  defp seconds(_), do: invalid()

  defp decode(value, :raw) when is_binary(value), do: {:ok, value}

  defp decode(value, :hex) when is_binary(value),
    do: decode_result(Base.decode16(value, case: :lower))

  defp decode(value, :hex_upper) when is_binary(value),
    do: decode_result(Base.decode16(value, case: :upper))

  defp decode(value, :hex_any) when is_binary(value),
    do: decode_result(Base.decode16(value, case: :mixed))

  defp decode(value, :base64) when is_binary(value),
    do: decode_result(Base.decode64(value, padding: false))

  defp decode(value, :base64url) when is_binary(value),
    do: decode_result(Base.url_decode64(value, padding: false))

  defp decode(_, _), do: invalid()
  defp decode_result({:ok, bytes}), do: {:ok, bytes}
  defp decode_result(:error), do: invalid()
  defp result(true), do: :ok
  defp result(false), do: invalid()
  defp invalid, do: {:error, :invalid_signature}

  defp safely(fun) do
    fun.()
  catch
    _, _ -> invalid()
  end
end
