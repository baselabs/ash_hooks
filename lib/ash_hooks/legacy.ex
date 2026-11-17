defmodule AshHooks.Legacy do
  @moduledoc """
  The legacy HMAC webhook envelope for receivers using the `:legacy` or
  `:dual` signing modes.

  `AshHooks.Legacy.verify/5` validates its signature.

  Envelope:

    * MAC: HMAC-SHA256 over `"<unix_ts>.<body>"`, lowercase hex.
    * `sign/3` → `"v1=<hex>"`; rotation appends `",v1prev=<hex>"` under the
      separately imported previous secret.
    * header: `x-webhook-signature: t=<unix_ts>,<signature>`.

  `headers/4` also accepts `AshHooks.Custody.Key` values of kind
  `{:legacy_hmac, :sha256}` for either slot, including mixed byte and custody
  rotation. Failures return classified errors; sender-only kinds are refused
  before custody is called. Byte clauses retain their existing behavior.

  Use `:dual` to send this envelope alongside Standard Webhooks while receivers
  migrate. New integrations should use `:standard`.
  """

  @signature_prefix "v1"
  @previous_signature_prefix "v1prev"
  alias AshHooks.Custody
  alias AshHooks.Custody.Key

  # -- Signing -------------------------------------------------------

  @doc "HMAC-SHA256 over `<unix_ts>.<body>`, lowercase hex, `v1=`-prefixed."
  @spec sign(binary(), binary(), integer()) :: String.t()
  def sign(secret, body, unix_ts)
      when is_binary(secret) and secret != "" and is_binary(body) and is_integer(unix_ts) and
             unix_ts > 0 do
    @signature_prefix <> "=" <> legacy_mac_hex(secret, body, unix_ts)
  end

  @doc "Current and previous signatures comma-joined (zero-downtime rotation)."
  @spec sign_with_previous(binary(), binary(), binary(), integer()) :: String.t()
  def sign_with_previous(current_secret, previous_secret, body, unix_ts)
      when is_binary(current_secret) and current_secret != "" and is_binary(previous_secret) and
             previous_secret != "" do
    current_signature = sign(current_secret, body, unix_ts)
    previous_signature = legacy_mac_hex(previous_secret, body, unix_ts)

    current_signature <> "," <> @previous_signature_prefix <> "=" <> previous_signature
  end

  @doc "Assembles the header value: `t=<unix_ts>,<signature>`."
  @spec header_value(String.t(), integer()) :: String.t()
  def header_value(signature, unix_ts) when is_binary(signature) and is_integer(unix_ts) do
    "t=" <> Integer.to_string(unix_ts) <> "," <> signature
  end

  @doc "The legacy header set: `x-webhook-signature` under `secret` (and optional `previous`)."
  @spec headers(binary() | Key.t(), binary() | Key.t() | nil, binary(), integer()) ::
          %{String.t() => String.t()} | {:error, struct() | :kind_not_allowed}
  def headers(secret, previous \\ nil, body, unix_ts)

  def headers(secret, previous, body, unix_ts)
      when is_struct(secret, Key) or is_struct(previous, Key) do
    with {:ok, current} <- custody_mac(secret, body, unix_ts),
         {:ok, previous} <- custody_mac(previous, body, unix_ts) do
      signature = "v1=" <> current
      signature = if previous, do: signature <> ",v1prev=" <> previous, else: signature
      %{"x-webhook-signature" => header_value(signature, unix_ts)}
    end
  end

  def headers(secret, previous, body, unix_ts) do
    signature =
      if previous do
        sign_with_previous(secret, previous, body, unix_ts)
      else
        sign(secret, body, unix_ts)
      end

    %{"x-webhook-signature" => header_value(signature, unix_ts)}
  end

  defp custody_mac(nil, _body, _unix_ts), do: {:ok, nil}

  defp custody_mac(%Key{kind: {:sender_hmac, _}}, _body, _unix_ts),
    do: {:error, :kind_not_allowed}

  defp custody_mac(%Key{kind: {:legacy_hmac, :sha256}} = key, body, unix_ts) do
    with {:ok, mac} <- Custody.sign(key, Integer.to_string(unix_ts) <> "." <> body),
         do: {:ok, Base.encode16(mac, case: :lower)}
  end

  defp custody_mac(%Key{}, _body, _unix_ts),
    do: AshHooks.Errors.from_custody_result({:error, :kind_mismatch})

  defp custody_mac(bytes, body, unix_ts), do: {:ok, legacy_mac_hex(bytes, body, unix_ts)}

  # -- Verification (the oracle) -------------------------------------

  @doc """
  Verifies a legacy header value: parses `t=`/`v1=`, compares hex digests
  in constant time, then checks the replay window. An invalid signature takes
  precedence over a stale timestamp.

  `window` defaults to 300 seconds, symmetric around `now_ts`.
  """
  @spec verify(binary(), binary(), binary(), integer(), integer()) ::
          {:ok, %{unix_ts: integer()}} | {:error, :invalid_signature | :stale_timestamp}
  def verify(secret, body, header, now_ts, window \\ 300)
      when is_binary(secret) and is_binary(body) and is_binary(header) and is_integer(now_ts) and
             is_integer(window) and window >= 0 do
    with {:ok, unix_ts, signature_hex} <- parse_header(header),
         true <-
           signature_matches?(secret, body, unix_ts, signature_hex) ||
             {:error, :invalid_signature},
         :ok <- check_replay_window(unix_ts, now_ts, window) do
      {:ok, %{unix_ts: unix_ts}}
    end
  end

  # -- Internals -----------------------------------------------------

  defp legacy_mac_hex(secret, body, unix_ts) do
    :crypto.mac(:hmac, :sha256, secret, [Integer.to_string(unix_ts), ?., body])
    |> Base.encode16(case: :lower)
  end

  # An empty secret matches nothing (fail closed); otherwise constant-time
  # compare behind a byte-size guard.
  defp signature_matches?(secret, body, unix_ts, signature_hex) do
    if secret == "" do
      false
    else
      expected = legacy_mac_hex(secret, body, unix_ts)

      byte_size(expected) == byte_size(signature_hex) and
        :crypto.hash_equals(expected, signature_hex)
    end
  end

  defp parse_header(header_value) do
    parts =
      header_value
      |> String.split(",", trim: true)
      |> Map.new(fn part ->
        case String.split(part, "=", parts: 2) do
          [key, value] -> {key, value}
          _invalid -> {"", ""}
        end
      end)

    with timestamp when is_binary(timestamp) <- Map.get(parts, "t"),
         signature when is_binary(signature) <- Map.get(parts, "v1"),
         {unix_ts, ""} <- Integer.parse(timestamp) do
      {:ok, unix_ts, signature}
    else
      _invalid -> {:error, :invalid_signature}
    end
  end

  defp check_replay_window(unix_ts, now_ts, window) do
    if abs(now_ts - unix_ts) <= window do
      :ok
    else
      {:error, :stale_timestamp}
    end
  end
end
