defmodule AshHooks.Legacy do
  @moduledoc """
  The incumbent webhook envelope, reproduced byte-identically for the
  `:dual` migration mode (ADR-0002), with `verify/5` as the in-package
  oracle proving that identity.

  Envelope (shape extracted first-hand from the adopting platform's
  `Webhooks.Signing` + its deliver worker — read-only reference):

    * MAC — HMAC-SHA256 over `"<unix_ts>.<body>"`, lowercase hex.
    * `sign/3` → `"v1=<hex>"`; rotation appends `",v1prev=<hex>"` under the
      separately imported previous secret.
    * header — `x-webhook-signature: t=<unix_ts>,<signature>`.

  This module exists for migration and is scheduled to shrink away as
  subscriptions cut over to `:standard`.
  """

  @signature_prefix "v1"
  @previous_signature_prefix "v1prev"

  # —— Signing ———————————————————————————————————————————————————————

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
  @spec headers(binary(), binary() | nil, binary(), integer()) :: %{String.t() => String.t()}
  def headers(secret, previous \\ nil, body, unix_ts) do
    signature =
      if previous do
        sign_with_previous(secret, previous, body, unix_ts)
      else
        sign(secret, body, unix_ts)
      end

    %{"x-webhook-signature" => header_value(signature, unix_ts)}
  end

  # —— Verification (the oracle) ————————————————————————————————————

  @doc """
  Verifies a legacy header value: parses `t=`/`v1=`, checks the replay
  window, compares hex digests in constant time.

  `window` defaults to 300 seconds, symmetric around `now_ts`.
  """
  @spec verify(binary(), binary(), binary(), integer(), integer()) ::
          {:ok, %{unix_ts: integer()}} | {:error, :invalid_signature | :stale_timestamp}
  def verify(secret, body, header, now_ts, window \\ 300)
      when is_binary(secret) and is_binary(body) and is_binary(header) and is_integer(now_ts) and
             is_integer(window) and window >= 0 do
    with {:ok, unix_ts, signature_hex} <- parse_header(header),
         :ok <- check_replay_window(unix_ts, now_ts, window) do
      if signature_matches?(secret, body, unix_ts, signature_hex) do
        {:ok, %{unix_ts: unix_ts}}
      else
        {:error, :invalid_signature}
      end
    end
  end

  # —— Internals ————————————————————————————————————————————————————

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
