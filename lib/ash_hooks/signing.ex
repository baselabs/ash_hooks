defmodule AshHooks.Signing do
  @moduledoc """
  Standard Webhooks canon signing and verification — `v1` (HMAC-SHA256) and
  `v1a` (ed25519) from day one (ADR-0006), over the canonical string
  `msg_id.timestamp.payload`.

  Conformance anchors: the official Go reference library's own test vector
  (`TestWebhookSign`) is reproduced byte-for-byte by `sign/4`; verification
  semantics (space-delimited multi-signatures, unknown version identifiers
  skipped, timestamp tolerance, `whsec_` prefix optional) match the official
  reference libraries read first-hand. ed25519 usage is anchored to RFC 8032
  §7.1 known-answers.

  Secret formats:

    * symmetric — `whsec_` + base64 of 24–64 random bytes (prefix optional,
      matching the references). `sign/4` enforces the 24–64 byte band (the
      spec's emitter guidance); `verify/4` rejects only EMPTY secrets so a
      vendor with a shorter secret still interoperates.
    * asymmetric — `whsk_` + base64 of the 32-byte ed25519 seed (signing),
      `whpk_` + base64 of the 32-byte public key (verification). Prefixes are
      required — they are what `verify/4` dispatches on.

  `headers_for_mode/5` is the single seam the delivery runtime uses to emit
  `:standard`, `:dual` (SW + byte-identical legacy envelope, ADR-0002), or
  `:legacy` headers.
  """

  alias AshHooks.Legacy

  @secret_prefix "whsec_"
  @priv_prefix "whsk_"
  @pub_prefix "whpk_"
  @id_prefix "msg_"
  @default_tolerance 300

  @ed25519_curve {:namedCurve, {1, 3, 101, 112}}

  @type verify_reason ::
          :missing_header
          | :invalid_timestamp
          | :timestamp_out_of_tolerance
          | :invalid_signature
          | :invalid_secret

  # —— Signing ———————————————————————————————————————————————————————

  @doc """
  Signs the canonical string with HMAC-SHA256 under the decoded symmetric
  secret: `"v1," <> base64(mac)`.

  Raises `ArgumentError` on invalid inputs — the send path fails loud on
  config or programming errors.
  """
  @spec sign(String.t(), integer(), binary(), String.t()) :: String.t()
  def sign(msg_id, unix_ts, payload, whsec)
      when is_binary(msg_id) and msg_id != "" and is_integer(unix_ts) and unix_ts > 0 and
             is_binary(payload) and is_binary(whsec) do
    if String.contains?(msg_id, ".") do
      raise ArgumentError,
            "msg_id must not contain \".\" — it is the canonical-string delimiter"
    end

    secret = decode_symmetric_secret!(whsec, 24..64)
    mac = :crypto.mac(:hmac, :sha256, secret, to_sign(msg_id, unix_ts, payload))
    "v1," <> Base.encode64(mac)
  end

  @doc """
  Signs the canonical string with ed25519 under the seed decoded from a
  `whsk_` secret: `"v1a," <> base64(signature)`.
  """
  @spec sign_ed25519(String.t(), integer(), binary(), String.t()) :: String.t()
  def sign_ed25519(msg_id, unix_ts, payload, whsk)
      when is_binary(msg_id) and msg_id != "" and is_integer(unix_ts) and unix_ts > 0 and
             is_binary(payload) and is_binary(whsk) do
    if String.contains?(msg_id, ".") do
      raise ArgumentError,
            "msg_id must not contain \".\" — it is the canonical-string delimiter"
    end

    seed = decode_asymmetric_secret!(whsk, @priv_prefix)

    priv =
      {:ECPrivateKey, :ecPrivkeyVer1, seed, @ed25519_curve, :asn1_NOVALUE, :asn1_NOVALUE}

    signature = :public_key.sign(to_sign(msg_id, unix_ts, payload), :none, priv)
    "v1a," <> Base.encode64(signature)
  end

  # —— Verification —————————————————————————————————————————————————

  @doc """
  Verifies a webhook's `webhook-id` / `webhook-timestamp` /
  `webhook-signature` headers against the raw payload.

  Dispatches on the secret's prefix: `whpk_` verifies `v1a` (ed25519)
  entries; anything else verifies `v1` (HMAC) entries and skips all other
  version identifiers, matching the official references.

  `headers` is a map with EXACTLY the lowercased header names as string keys
  and single binary values (`"webhook-id"`, `"webhook-timestamp"`,
  `"webhook-signature"`) — the shape Plug and the inbound seam supply after
  normalization. Mixed-case keys or multi-value header lists are
  `{:error, :missing_header}` (fail closed); callers normalize before this
  boundary.

  Options:

    * `:now` — integer unix seconds (default `System.system_time(:second)`).
    * `:tolerance` — allowed `|now - timestamp|` in seconds (default 300).
    * `:ignore_timestamp` — skip the tolerance check (dead-letter re-drives,
      offline verification); the timestamp must still parse.

  Returns `{:ok, %{id: id, timestamp: ts}}` or `{:error, reason}`. Never
  raises on hostile input.
  """
  @spec verify(binary(), map(), String.t(), keyword()) ::
          {:ok, %{id: String.t(), timestamp: integer()}} | {:error, verify_reason()}
  def verify(payload, headers, secret, opts \\ [])

  def verify(payload, headers, @pub_prefix <> _ = whpk, opts)
      when is_binary(payload) and is_map(headers) and is_binary(whpk) do
    with {:ok, public_key} <- normalize_public_key(whpk),
         {:ok, id, ts, signature_header} <- required_headers(headers),
         :ok <- check_timestamp(ts, opts) do
      signed = to_sign(id, ts, payload)

      if Enum.any?(
           signature_entries(signature_header, "v1a"),
           &asymmetric_match?(public_key, signed, &1)
         ) do
        {:ok, %{id: id, timestamp: ts}}
      else
        {:error, :invalid_signature}
      end
    end
  end

  def verify(payload, headers, whsec, opts)
      when is_binary(payload) and is_map(headers) and is_binary(whsec) do
    with {:ok, id, ts, signature_header} <- required_headers(headers),
         :ok <- check_timestamp(ts, opts),
         {:ok, secret} <- decode_verify_secret(whsec) do
      expected = :crypto.mac(:hmac, :sha256, secret, to_sign(id, ts, payload))

      if Enum.any?(signature_entries(signature_header, "v1"), &symmetric_match?(expected, &1)) do
        {:ok, %{id: id, timestamp: ts}}
      else
        {:error, :invalid_signature}
      end
    end
  end

  # —— Header assembly ——————————————————————————————————————————————

  @doc """
  The three Standard Webhooks headers. `:whsec` and/or `:whsk` select the
  signature schemes (both day one); `:previous_whsec` appends the rotated-out
  secret's signature (space-delimited, per the spec's zero-downtime
  rotation).
  """
  @spec headers(String.t(), integer(), binary(), keyword()) :: %{String.t() => String.t()}
  def headers(msg_id, unix_ts, payload, opts \\ []) do
    signatures =
      []
      |> append_signature(&sign/4, [msg_id, unix_ts, payload], opts[:whsec])
      |> append_signature(&sign/4, [msg_id, unix_ts, payload], opts[:previous_whsec])
      |> append_signature(&sign_ed25519/4, [msg_id, unix_ts, payload], opts[:whsk])

    if signatures == [] do
      raise ArgumentError, "headers/4 needs at least one of :whsec, :previous_whsec or :whsk"
    end

    %{
      "webhook-id" => msg_id,
      "webhook-timestamp" => Integer.to_string(unix_ts),
      "webhook-signature" => Enum.join(signatures, " ")
    }
  end

  @doc """
  The full header set for a subscription's `signing_mode` (ADR-0002):

    * `:standard` — the three SW headers.
    * `:dual` — SW headers PLUS the byte-identical legacy envelope
      (`x-webhook-signature`, via `AshHooks.Legacy`); requires
      `:legacy_secret` (dual MEANS both envelopes).
    * `:legacy` — the legacy envelope only.

  Legacy options: `:legacy_secret`, `:legacy_previous_secret`. SW options:
  `:whsec`, `:whsk`, `:previous_whsec`.
  """
  @spec headers_for_mode(:legacy | :dual | :standard, String.t(), integer(), binary(), keyword()) ::
          %{String.t() => String.t()}
  def headers_for_mode(mode, msg_id, unix_ts, body, opts)

  def headers_for_mode(:standard, msg_id, unix_ts, body, opts),
    do: headers(msg_id, unix_ts, body, opts)

  def headers_for_mode(:legacy, _msg_id, unix_ts, body, opts) do
    unless is_binary(opts[:legacy_secret]) and opts[:legacy_secret] != "" do
      raise ArgumentError, ":legacy signing_mode requires :legacy_secret (the incumbent secret)"
    end

    Legacy.headers(opts[:legacy_secret], opts[:legacy_previous_secret], body, unix_ts)
  end

  def headers_for_mode(:dual, msg_id, unix_ts, body, opts) do
    unless is_binary(opts[:legacy_secret]) and opts[:legacy_secret] != "" do
      raise ArgumentError, ":dual signing_mode requires :legacy_secret (the incumbent secret)"
    end

    Map.merge(
      headers(msg_id, unix_ts, body, opts),
      Legacy.headers(opts[:legacy_secret], opts[:legacy_previous_secret], body, unix_ts)
    )
  end

  # —— Generation ———————————————————————————————————————————————————

  @doc "A fresh `whsec_`-prefixed secret (24–64 decoded bytes, spec band)."
  @spec generate_secret(pos_integer()) :: String.t()
  def generate_secret(bytes \\ 32) when bytes in 24..64 do
    @secret_prefix <> Base.encode64(:crypto.strong_rand_bytes(bytes))
  end

  @doc "A fresh ed25519 keypair as `{whsk, whpk}`."
  @spec generate_signing_keypair() :: {String.t(), String.t()}
  def generate_signing_keypair do
    seed = :crypto.strong_rand_bytes(32)
    {public_key, _} = :crypto.generate_key(:eddsa, :ed25519, seed)
    {@priv_prefix <> Base.encode64(seed), @pub_prefix <> Base.encode64(public_key)}
  end

  @doc "A fresh `msg_`-prefixed webhook id (URL-safe, never contains `.`)."
  @spec generate_msg_id() :: String.t()
  def generate_msg_id do
    @id_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  # —— Internals ————————————————————————————————————————————————————

  defp to_sign(msg_id, unix_ts, payload) do
    IO.iodata_to_binary([msg_id, ?., Integer.to_string(unix_ts), ?., payload])
  end

  defp symmetric_match?(expected, signature) do
    case decode_b64(signature) do
      {:ok, sig_bytes} ->
        byte_size(expected) == byte_size(sig_bytes) and
          :crypto.hash_equals(expected, sig_bytes)

      :error ->
        false
    end
  end

  defp asymmetric_match?(public_key, signed, signature) do
    case decode_b64(signature) do
      {:ok, sig_bytes} ->
        verify_key = {{:ECPoint, public_key}, @ed25519_curve}

        byte_size(sig_bytes) == 64 and
          :public_key.verify(signed, :none, sig_bytes, verify_key)

      :error ->
        false
    end
  end

  defp signature_entries(signature_header, version) do
    signature_header
    |> String.split(" ", trim: true)
    |> Enum.flat_map(fn entry ->
      case String.split(entry, ",", parts: 2) do
        [^version, signature] -> [signature]
        _other -> []
      end
    end)
  end

  defp required_headers(headers) do
    id = header(headers, "webhook-id")
    ts = header(headers, "webhook-timestamp")
    signature = header(headers, "webhook-signature")

    if id && ts && signature do
      case Integer.parse(ts) do
        {unix_ts, ""} when is_integer(unix_ts) -> {:ok, id, unix_ts, signature}
        _other -> {:error, :invalid_timestamp}
      end
    else
      {:error, :missing_header}
    end
  end

  defp header(headers, name) do
    case Map.fetch(headers, name) do
      {:ok, value} when is_binary(value) -> value
      _ -> nil
    end
  end

  defp check_timestamp(ts, opts) do
    if opts[:ignore_timestamp] do
      :ok
    else
      now = Keyword.get(opts, :now, System.system_time(:second))
      tolerance = Keyword.get(opts, :tolerance, @default_tolerance)

      if abs(now - ts) <= tolerance do
        :ok
      else
        {:error, :timestamp_out_of_tolerance}
      end
    end
  end

  defp decode_verify_secret(whsec) do
    case decode_b64(strip_prefix(whsec, @secret_prefix)) do
      {:ok, secret} when byte_size(secret) > 0 -> {:ok, secret}
      {:ok, _empty} -> {:error, :invalid_secret}
      :error -> {:error, :invalid_secret}
    end
  end

  defp decode_symmetric_secret!(whsec, bytes_range) do
    secret =
      whsec
      |> strip_prefix(@secret_prefix)
      |> decode_b64!()

    unless byte_size(secret) in bytes_range do
      raise ArgumentError,
            "symmetric secret must decode to #{inspect(bytes_range)} bytes " <>
              "(whsec_ base64) — got #{byte_size(secret)}"
    end

    secret
  end

  defp decode_asymmetric_secret!(prefixed, prefix) do
    case decode_asymmetric_secret(prefixed, prefix) do
      {:ok, decoded} ->
        decoded

      {:error, reason} ->
        raise ArgumentError, reason
    end
  end

  # Non-raising twin for the verify path — a malformed key is a fail-closed
  # {:error, :invalid_secret}, never an exception.
  defp normalize_public_key(whpk) do
    case decode_asymmetric_secret(whpk, @pub_prefix) do
      {:ok, public_key} -> {:ok, public_key}
      {:error, _reason} -> {:error, :invalid_secret}
    end
  end

  defp decode_asymmetric_secret(prefixed, prefix) do
    if String.starts_with?(prefixed, prefix) do
      case prefixed |> strip_prefix(prefix) |> decode_b64() do
        {:ok, decoded} when byte_size(decoded) == 32 ->
          {:ok, decoded}

        {:ok, _wrong_size} ->
          {:error, "#{prefix} key must decode to exactly 32 bytes (base64 ed25519)"}

        :error ->
          {:error, "#{prefix} key is not valid base64"}
      end
    else
      {:error, "asymmetric key must be #{prefix}-prefixed base64"}
    end
  end

  defp strip_prefix(value, prefix), do: String.replace_prefix(value, prefix, "")

  defp decode_b64!(encoded) do
    case decode_b64(encoded) do
      {:ok, decoded} -> decoded
      # Never echo the value — it may be live secret material (ADR-0005).
      :error -> raise ArgumentError, "secret is not valid base64 (#{byte_size(encoded)} bytes)"
    end
  end

  # Tolerate unpadded base64 like the python reference — `padding: false`
  # accepts any correct unpadded length (appending "==" only rescues
  # length ≡ 2 mod 4, wrongly rejecting the unpadded 32-byte secret form).
  defp decode_b64(encoded) when is_binary(encoded) and encoded != "" do
    case Base.decode64(encoded) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> Base.decode64(encoded, padding: false)
    end
  end

  defp decode_b64(_other), do: :error

  defp append_signature(list, _sign, _args, nil), do: list
  defp append_signature(list, sign, args, secret), do: list ++ [apply(sign, args ++ [secret])]
end
