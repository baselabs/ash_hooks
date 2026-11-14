defmodule AshHooks.Provider.Scheme do
  @moduledoc """
  A caller-configured webhook verification contract.

  The [Verify any sender](verify-any-sender.md) guide has recipes for common
  signature shapes.

  Define a provider with `use AshHooks.Provider, verify: [...]` or validate trusted
  options with `new!/1` and call `verify/4`. Request data never chooses algorithms,
  keys, encodings, or canonicalization callbacks.

  Required options are `algorithm:` and `signature:`. Algorithms are
  `:hmac_sha1`, `:hmac_sha256`, `:hmac_sha384`, `:hmac_sha512`,
  `:rsa_pkcs1_sha256`, `:rsa_pkcs1_sha384`, `:rsa_pkcs1_sha512`,
  `:rsa_pss_sha256`, `:rsa_pss_sha384`, `:rsa_pss_sha512`,
  `:ecdsa_p256_sha256`, `:ecdsa_p384_sha384`, and `:ed25519`.
  ECDSA algorithms pin the curve as well as the digest.

  `signature:` accepts `{:header, name}`, `{:header, name, prefix: prefix}`,
  `{:structured_header, name, signature_key: key}`, or `:jws_body`. A header prefix
  matches ASCII case-insensitively. Structured headers support `pair_separator:`
  (default `","`) and `key_value_separator:` (default `"="`), consider at most 16
  matching signatures, and accept any matching signature.

  Other options:

    * `encoding`: `:hex`, `:hex_upper`, `:hex_any`, `:base64`, or `:base64url`;
      default `:hex` for HMAC, `:base64` for public keys.
    * `ecdsa_format`: `:der` (default) or `:raw`, only for ECDSA.
    * `key_encoding`: `:raw` (default), `:hex`, `:base64`, or `:base64url` for
      HMAC secrets and raw Ed25519 keys. PEM is detected automatically.
    * `key_prefix`: optional literal prefix removed before key decoding when present.
    * `signed_input`: `:body` (default), a nonempty list of binary literals,
      `:body`, `:timestamp`, `:method`, `:url`, `:path`, `{:header, name}`, or
      `{:base64, part}`, concatenated without separators. Alternatively a
      `{module, function}` or two-argument function `(raw_body, ctx) -> binary`.
      `:path` preserves encoding and excludes the query; `:url` preserves the URI.
    * `timestamp`: `nil` (default), `{:header, name}`, `{:signature_field, key}`
      for structured signatures, or a `{module, function}` / two-argument function
      returning `{:ok, unix_seconds}` or `:error`.
    * `timestamp_unit`: `:seconds` (default) or `:milliseconds` for header/field
      timestamps. Milliseconds use integer division by 1000.
    * `tolerance_seconds`: positive integer, default 300; overridden by
      `ctx[:replay_window_seconds]`. The clock is `ctx[:now_ms]` or system time.

  A configured JWS-body provider deduplicates on `payload_identity/1` unless the
  inbound declaration sets an `event_id` extractor or the provider overrides
  `event_identity/1`.

  JWS bodies derive the pinned JWS algorithm from `algorithm:`. They reject
  HMAC-SHA1 and any `encoding:`, `ecdsa_format:`, `signed_input:` or
  `timestamp_unit:`. A `timestamp:` must be a host function, and
  `tolerance_seconds:` requires one. JSON object
  `exp`/`nbf` claims are also enforced by `AshHooks.Provider.Signature.jws/3`.

  Keys are decoded first, then signatures extracted and input built. Timestamp
  checks run only after successful authentication. Certificates are pinned key
  containers only; no chain, expiration, or revocation validation is performed.
  """
  alias AshHooks.Provider.Signature
  alias AshHooks.Provider.Signature.Key

  @algorithms %{
    hmac_sha1: {:hmac, :sha1, nil},
    hmac_sha256: {:hmac, :sha256, "HS256"},
    hmac_sha384: {:hmac, :sha384, "HS384"},
    hmac_sha512: {:hmac, :sha512, "HS512"},
    rsa_pkcs1_sha256: {:rsa, :sha256, "RS256"},
    rsa_pkcs1_sha384: {:rsa, :sha384, "RS384"},
    rsa_pkcs1_sha512: {:rsa, :sha512, "RS512"},
    rsa_pss_sha256: {:rsa, :sha256, "PS256"},
    rsa_pss_sha384: {:rsa, :sha384, "PS384"},
    rsa_pss_sha512: {:rsa, :sha512, "PS512"},
    ecdsa_p256_sha256: {:ecdsa, :sha256, "ES256"},
    ecdsa_p384_sha384: {:ecdsa, :sha384, "ES384"},
    ed25519: {:ed25519, :none, "EdDSA"}
  }
  @options [
    :algorithm,
    :signature,
    :encoding,
    :ecdsa_format,
    :key_encoding,
    :key_prefix,
    :signed_input,
    :timestamp,
    :timestamp_unit,
    :tolerance_seconds
  ]
  defstruct @options
  @type t :: %__MODULE__{}

  @doc "Validates trusted options and returns a normalized scheme; invalid configuration raises `ArgumentError`."
  @spec new!(term()) :: t()
  def new!(opts) when is_list(opts) do
    validate_suboptions(opts, @options, "scheme")

    algorithm = opts[:algorithm]

    require_option(
      Map.has_key?(@algorithms, algorithm),
      "algorithm must be one of #{inspect(Map.keys(@algorithms))}"
    )

    {type, _, _} = @algorithms[algorithm]
    signature = normalize_signature(opts[:signature])
    encoding = Keyword.get(opts, :encoding, if(type == :hmac, do: :hex, else: :base64))

    require_option(
      encoding in [:hex, :hex_upper, :hex_any, :base64, :base64url],
      "encoding must be :hex, :hex_upper, :hex_any, :base64, or :base64url"
    )

    require_option(
      not Keyword.has_key?(opts, :ecdsa_format) or type == :ecdsa,
      "ecdsa_format is only valid for ECDSA algorithms"
    )

    require_option(
      Keyword.get(opts, :ecdsa_format, :der) in [:der, :raw],
      "ecdsa_format must be :der or :raw"
    )

    require_option(
      Keyword.get(opts, :key_encoding, :raw) in [:raw, :hex, :base64, :base64url],
      "key_encoding must be :raw, :hex, :base64, or :base64url"
    )

    require_option(
      is_nil(opts[:key_prefix]) or is_binary(opts[:key_prefix]),
      "key_prefix must be a binary"
    )

    require_option(
      Keyword.get(opts, :timestamp_unit, :seconds) in [:seconds, :milliseconds],
      "timestamp_unit must be :seconds or :milliseconds"
    )

    tolerance = Keyword.get(opts, :tolerance_seconds, 300)

    require_option(
      is_integer(tolerance) and tolerance > 0,
      "tolerance_seconds must be a positive integer"
    )

    validate_timestamp(opts[:timestamp], signature)
    signed_input = Keyword.get(opts, :signed_input, :body)

    require_option(
      valid_input?(signed_input),
      "signed_input must be :body, a nonempty list of valid parts, or a two-argument callback"
    )

    require_option(
      not uses_timestamp?(signed_input) or match?({:header, _}, opts[:timestamp]) or
        match?({:signature_field, _}, opts[:timestamp]),
      "signed_input :timestamp requires a timestamp header or signature field"
    )

    if signature == :jws_body, do: validate_jws(opts, algorithm)

    struct!(__MODULE__,
      algorithm: algorithm,
      signature: signature,
      encoding: encoding,
      ecdsa_format: Keyword.get(opts, :ecdsa_format, :der),
      key_encoding: Keyword.get(opts, :key_encoding, :raw),
      key_prefix: opts[:key_prefix],
      signed_input: signed_input,
      timestamp: opts[:timestamp],
      timestamp_unit: Keyword.get(opts, :timestamp_unit, :seconds),
      tolerance_seconds: tolerance
    )
  end

  def new!(_opts), do: raise(ArgumentError, "options must be a keyword list")

  @doc """
  Verifies exact request bytes using a validated scheme or trusted keyword options.

  Keyword options are validated first: an invalid configuration raises
  `ArgumentError`, as `new!/1` does. Request data never raises; it returns an error.
  """
  @spec verify(binary(), map(), term(), t() | keyword()) :: :ok | Signature.error()
  def verify(raw_body, ctx, keys, opts) when is_list(opts),
    do: verify(raw_body, ctx, keys, new!(opts))

  def verify(raw_body, ctx, keys, %__MODULE__{} = scheme) do
    with true <- is_binary(raw_body) and is_map(ctx),
         {:ok, keys} <- decode_keys(keys, scheme),
         {:ok, signatures, fields} <- signatures(raw_body, ctx, scheme),
         input when is_binary(input) <- signed_input(raw_body, ctx, fields, scheme),
         :ok <- authenticate(input, signatures, keys, ctx, scheme) do
      check_timestamp(raw_body, ctx, fields, scheme)
    else
      {:error, _} = error -> error
      _ -> invalid()
    end
  rescue
    _ -> invalid()
  catch
    _, _ -> invalid()
  end

  def verify(_raw_body, _ctx, _keys, _other),
    do: raise(ArgumentError, "expected an AshHooks.Provider.Scheme or keyword options")

  @doc "Returns the configured timestamp header, or `nil` for absent and host-function timestamps."
  def timestamp_header(%__MODULE__{timestamp: {:header, name}}), do: name

  def timestamp_header(%__MODULE__{
        timestamp: {:signature_field, _},
        signature: {:structured_header, name, _}
      }),
      do: name

  def timestamp_header(%__MODULE__{}), do: nil

  @doc "Returns `:body` for JWS envelopes and `:request` for header-based signatures."
  def signature_source(%__MODULE__{signature: :jws_body}), do: :body
  def signature_source(%__MODULE__{}), do: :request

  @doc "Decodes a JWS body's payload to a JSON map or list; this helper does not authenticate it."
  def decode_payload(raw_body, %__MODULE__{signature: :jws_body}) when is_binary(raw_body) do
    with [_, payload, _] <- :binary.split(raw_body, ".", [:global]),
         {:ok, bytes} <- Base.url_decode64(payload, padding: false),
         {:ok, value} when is_map(value) or is_list(value) <- Jason.decode(bytes) do
      {:ok, value}
    else
      _ -> {:error, :malformed_payload}
    end
  end

  def decode_payload(_, _), do: {:error, :malformed_payload}

  @doc """
  The default deduplication identity of a configured JWS-body provider: the
  lowercase hex SHA-256 of the verified payload as canonical JSON (object keys
  sorted). Two encodings of the same signed content, such as an ECDSA signature
  and its equally valid negated form, therefore share one ledger identity.
  """
  @spec payload_identity(term()) :: {:ok, String.t()} | {:error, :malformed_payload}
  def payload_identity(payload) when is_map(payload) or is_list(payload),
    do: {:ok, :crypto.hash(:sha256, canonical_json(payload)) |> Base.encode16(case: :lower)}

  def payload_identity(_payload), do: {:error, :malformed_payload}

  defp canonical_json(map) when is_map(map) do
    pairs =
      map
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, value} -> [Jason.encode!(key), ?:, canonical_json(value)] end)

    [?{, Enum.intersperse(pairs, ?,), ?}]
  end

  defp canonical_json(list) when is_list(list),
    do: [?[, Enum.intersperse(Enum.map(list, &canonical_json/1), ?,), ?]]

  defp canonical_json(value), do: Jason.encode!(value)

  defp normalize_signature({:header, name}) do
    require_option(nonempty?(name), "signature header name must be a nonempty binary")
    {:header, name, []}
  end

  defp normalize_signature({:header, name, opts}) do
    validate_suboptions(opts, [:prefix], "signature header")
    require_option(nonempty?(name), "signature header name must be a nonempty binary")
    require_option(is_binary(opts[:prefix]), "signature prefix must be a binary")
    {:header, name, opts}
  end

  defp normalize_signature({:structured_header, name, opts}) do
    validate_suboptions(
      opts,
      [:signature_key, :pair_separator, :key_value_separator],
      "structured_header"
    )

    require_option(nonempty?(name), "structured_header name must be a nonempty binary")

    require_option(
      nonempty?(opts[:signature_key]),
      "structured_header requires a nonempty signature_key"
    )

    pair = Keyword.get(opts, :pair_separator, ",")
    separator = Keyword.get(opts, :key_value_separator, "=")
    require_option(nonempty?(pair), "pair_separator must be a nonempty binary")
    require_option(nonempty?(separator), "key_value_separator must be a nonempty binary")

    {:structured_header, name,
     [signature_key: opts[:signature_key], pair_separator: pair, key_value_separator: separator]}
  end

  defp normalize_signature(:jws_body), do: :jws_body

  defp normalize_signature(_),
    do: raise(ArgumentError, "signature must be a header, structured_header, or :jws_body")

  defp validate_suboptions(opts, allowed, label) do
    require_option(Keyword.keyword?(opts), "#{label} options must be a keyword list")
    keys = Keyword.keys(opts)
    unknown = Enum.uniq(keys) -- allowed
    require_option(unknown == [], "unknown #{label} options: #{inspect(unknown)}")

    require_option(
      length(keys) == length(Enum.uniq(keys)),
      "duplicate #{label} options"
    )
  end

  defp validate_timestamp(nil, _), do: :ok

  defp validate_timestamp({:header, name}, _),
    do: require_option(nonempty?(name), "timestamp header must be a nonempty binary")

  defp validate_timestamp({:signature_field, key}, signature) do
    require_option(
      match?({:structured_header, _, _}, signature),
      "timestamp signature_field requires a structured_header signature"
    )

    require_option(nonempty?(key), "timestamp signature_field key must be a nonempty binary")
  end

  defp validate_timestamp(callback, _),
    do:
      require_option(
        callback?(callback),
        "timestamp must be a header, signature_field, or two-argument callback"
      )

  defp validate_jws(opts, algorithm) do
    require_option(algorithm != :hmac_sha1, ":jws_body does not support :hmac_sha1")

    for option <- [:encoding, :ecdsa_format, :signed_input, :timestamp_unit] do
      require_option(
        not Keyword.has_key?(opts, option),
        "#{option} cannot be configured with :jws_body"
      )
    end

    require_option(
      not Keyword.has_key?(opts, :timestamp) or callback?(opts[:timestamp]),
      ":jws_body timestamp must be a host function"
    )

    require_option(
      not Keyword.has_key?(opts, :tolerance_seconds) or callback?(opts[:timestamp]),
      ":jws_body tolerance_seconds requires a host timestamp function"
    )
  end

  defp valid_input?(:body), do: true

  defp valid_input?(parts) when is_list(parts),
    do: parts != [] and Enum.all?(parts, &valid_part?/1)

  defp valid_input?(callback), do: callback?(callback)

  defp valid_part?(part)
       when is_binary(part) or part in [:body, :timestamp, :method, :url, :path], do: true

  defp valid_part?({:header, name}), do: nonempty?(name)
  defp valid_part?({:base64, part}), do: valid_part?(part)
  defp valid_part?(_), do: false
  defp uses_timestamp?(parts) when is_list(parts), do: Enum.any?(parts, &uses_timestamp?/1)
  defp uses_timestamp?({:base64, part}), do: uses_timestamp?(part)
  defp uses_timestamp?(part), do: part == :timestamp

  defp callback?({module, function}),
    do: is_atom(module) and not is_nil(module) and is_atom(function) and not is_nil(function)

  defp callback?(fun), do: is_function(fun, 2)
  defp nonempty?(value), do: is_binary(value) and value != ""
  defp require_option(true, _), do: :ok
  defp require_option(false, message), do: raise(ArgumentError, message)

  defp decode_keys(keys, scheme) do
    with {:ok, keys} <- Key.list(keys) do
      results = Enum.map(keys, &decode_key(&1, scheme))
      decoded = for {:ok, key} <- results, do: key

      cond do
        decoded != [] -> {:ok, decoded}
        Enum.all?(results, &(&1 == {:error, :no_webhook_secret})) -> {:error, :no_webhook_secret}
        true -> invalid()
      end
    end
  end

  defp decode_key(key, scheme) do
    {type, _, _} = @algorithms[scheme.algorithm]

    with {:ok, key} <- key_bytes(key, type, scheme) do
      match_key(key, type, scheme.algorithm)
    end
  end

  defp match_key(key, :hmac, _) when is_binary(key) and key != "", do: {:ok, key}
  defp match_key(_, :hmac, _), do: invalid()
  defp match_key(key, :ecdsa, algorithm), do: Key.decode(key, {:ecdsa, curve(algorithm)})
  defp match_key(key, type, _), do: Key.decode(key, type)

  defp key_bytes(key, type, scheme) when is_binary(key) do
    key = strip_prefix(key, scheme.key_prefix)

    cond do
      key == "" -> {:error, :no_webhook_secret}
      String.starts_with?(key, "-----BEGIN") -> {:ok, key}
      type in [:hmac, :ed25519] -> decode_key_bytes(key, scheme.key_encoding)
      true -> {:ok, key}
    end
  end

  defp key_bytes(key, _, _), do: {:ok, key}
  defp strip_prefix(key, nil), do: key

  defp strip_prefix(key, prefix) do
    if String.starts_with?(key, prefix),
      do: binary_part(key, byte_size(prefix), byte_size(key) - byte_size(prefix)),
      else: key
  end

  defp decode_key_bytes(key, :raw), do: {:ok, key}
  defp decode_key_bytes(key, :hex), do: decode_result(Base.decode16(key, case: :mixed))
  defp decode_key_bytes(key, :base64), do: decode_result(Base.decode64(key, padding: false))

  defp decode_key_bytes(key, :base64url),
    do: decode_result(Base.url_decode64(key, padding: false))

  defp decode_result({:ok, bytes}), do: {:ok, bytes}
  defp decode_result(:error), do: invalid()

  defp signatures(raw, _, %__MODULE__{signature: :jws_body}), do: {:ok, [raw], []}

  defp signatures(_, ctx, %__MODULE__{signature: {:header, name, opts}}) do
    with value when is_binary(value) <- Signature.header(ctx, name),
         {:ok, value} <- signature_prefix(value, opts[:prefix]) do
      {:ok, [value], []}
    else
      _ -> invalid()
    end
  end

  defp signatures(_, ctx, %__MODULE__{signature: {:structured_header, name, opts}}) do
    case Signature.header(ctx, name) do
      value when is_binary(value) -> structured_signatures(value, opts)
      _ -> invalid()
    end
  end

  defp structured_signatures(value, opts) do
    fields =
      value
      |> String.split(opts[:pair_separator])
      |> Enum.map(fn pair ->
        pair |> String.trim() |> String.split(opts[:key_value_separator], parts: 2)
      end)

    candidates = for [key, value] <- fields, key == opts[:signature_key], do: value
    if length(candidates) in 1..16, do: {:ok, candidates, fields}, else: invalid()
  end

  defp signature_prefix(value, nil), do: {:ok, value}

  defp signature_prefix(value, prefix) do
    size = byte_size(prefix)

    if byte_size(value) >= size and
         String.downcase(binary_part(value, 0, size), :ascii) == String.downcase(prefix, :ascii),
       do: {:ok, binary_part(value, size, byte_size(value) - size)},
       else: invalid()
  end

  defp signed_input(raw, _, _, %__MODULE__{signature: :jws_body}), do: raw

  defp signed_input(raw, ctx, fields, scheme),
    do: input(scheme.signed_input, raw, ctx, fields, scheme)

  defp input(:body, raw, _, _, _), do: raw

  defp input(:timestamp, _, ctx, fields, scheme),
    do: timestamp_text(ctx, fields, scheme.timestamp)

  defp input(:method, _, ctx, _, _), do: ctx[:method]
  defp input(:url, _, ctx, _, _), do: ctx[:request_uri]

  defp input(:path, _, ctx, _, _) do
    case ctx[:request_uri] do
      uri when is_binary(uri) -> URI.parse(uri).path
      _ -> nil
    end
  end

  defp input({:header, name}, _, ctx, _, _), do: Signature.header(ctx, name)

  defp input({:base64, part}, raw, ctx, fields, scheme) do
    case input(part, raw, ctx, fields, scheme) do
      value when is_binary(value) -> Base.encode64(value)
      _ -> nil
    end
  end

  defp input(parts, raw, ctx, fields, scheme) when is_list(parts) do
    values = Enum.map(parts, &input(&1, raw, ctx, fields, scheme))
    if Enum.all?(values, &is_binary/1), do: IO.iodata_to_binary(values)
  end

  defp input(literal, _, _, _, _) when is_binary(literal), do: literal
  defp input(callback, raw, ctx, _, _), do: call(callback, raw, ctx)
  defp call({module, function}, raw, ctx), do: apply(module, function, [raw, ctx])
  defp call(fun, raw, ctx), do: fun.(raw, ctx)

  defp authenticate(_input, signatures, keys, ctx, %__MODULE__{signature: :jws_body} = scheme) do
    {_, _, alg} = @algorithms[scheme.algorithm]

    case Signature.jws(hd(signatures), keys, alg: alg, now_ms: ctx[:now_ms]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp authenticate(input, signatures, keys, _, scheme) do
    {type, digest, alg} = @algorithms[scheme.algorithm]
    opts = [digest: digest, encoding: scheme.encoding]

    opts =
      case type do
        :rsa ->
          Keyword.put(
            opts,
            :padding,
            if(String.starts_with?(alg, "PS"), do: :pss, else: :pkcs1_v1_5)
          )

        :ecdsa ->
          Keyword.put(opts, :format, scheme.ecdsa_format)

        _ ->
          opts
      end

    if Enum.any?(signatures, &(apply(Signature, type, [input, &1, keys, opts]) == :ok)),
      do: :ok,
      else: invalid()
  end

  defp timestamp_text(ctx, _, {:header, name}), do: Signature.header(ctx, name)

  defp timestamp_text(_, fields, {:signature_field, wanted}) do
    case for([key, value] <- fields, key == wanted, do: value) do
      [value] -> value
      _ -> nil
    end
  end

  defp timestamp_text(_, _, _), do: nil
  defp check_timestamp(_, _, _, %__MODULE__{timestamp: nil}), do: :ok

  defp check_timestamp(raw, ctx, fields, scheme) do
    case timestamp_value(raw, ctx, fields, scheme) do
      {:ok, value} ->
        Signature.check_timestamp(
          value,
          ctx,
          ctx[:replay_window_seconds] || scheme.tolerance_seconds
        )

      _ ->
        invalid()
    end
  end

  defp timestamp_value(_, ctx, fields, %{timestamp: {source, _}} = scheme)
       when source in [:header, :signature_field],
       do: parse_timestamp(timestamp_text(ctx, fields, scheme.timestamp), scheme.timestamp_unit)

  defp timestamp_value(raw, ctx, _, scheme), do: call(scheme.timestamp, raw, ctx)

  defp parse_timestamp(text, unit) when is_binary(text) and text != "" do
    if Enum.all?(:binary.bin_to_list(text), &(&1 in ?0..?9)) do
      value = String.to_integer(text)
      {:ok, if(unit == :milliseconds, do: div(value, 1000), else: value)}
    else
      :error
    end
  end

  defp parse_timestamp(_, _), do: :error

  defp curve(:ecdsa_p256_sha256), do: {1, 2, 840, 10_045, 3, 1, 7}
  defp curve(:ecdsa_p384_sha384), do: {1, 3, 132, 0, 34}
  defp invalid, do: {:error, :invalid_signature}
end
