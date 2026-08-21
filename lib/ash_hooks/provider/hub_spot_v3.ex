defmodule AshHooks.Provider.HubSpotV3 do
  @moduledoc """
  HubSpot v3 webhook verifier: HMAC-SHA256 over the concatenated canonical
  string `requestMethod + requestUri + requestBody + timestamp` (no
  separators), keyed with the app's client secret, base64-encoded — carried
  in the `X-HubSpot-Signature-v3` header, with the millisecond timestamp in
  a SEPARATE `X-HubSpot-Request-Timestamp` header (verified against the
  vendor docs first-hand 2026-08-21; the acceptance vector is the docs
  page's own Java example, quoted in
  `test/ash_hooks/provider/hub_spot_v3_test.exs`). Sign the raw body bytes
  exactly as received and reconstruct the signed URI caller-side as
  `"https://" <> conn.host <> conn.request_path <> conn.query_string` — the
  provider then decodes the vendor's documented percent-encodings via
  `decode_request_uri/1`. Behind a TLS-terminating proxy the host must be
  the public value HubSpot called.

  Replay window: the vendor's validation step 1 — reject a timestamp older
  than five minutes — is enforced BY DEFAULT (300 seconds, one-sided
  past-only, matching both vendor code samples; a future timestamp is not
  a replay vector because the signature binds it). An inbound's
  `replay_window_seconds` overrides the default in either direction.
  Setting it ABOVE 300 weakens replay protection; the vendor default means
  a bare declaration is already safe.

  `parse_event_type/1`: HubSpot delivers a top-level ARRAY of event objects
  (under 100, `eventId` explicitly not guaranteed unique, duplicates
  possible per event — the ledger's default content-digest identity dedupes
  byte-identical redeliveries). A homogeneous batch maps to its
  subscriptionType's atom via the 41-entry vendor-documented allowlist; a
  mixed batch of known types maps to `:mixed` (fan out per event
  consumer-side); an unknown type string anywhere in the batch fails closed
  as `{:error, :unknown_event_type}` and lands `failed_permanent` in the
  ledger — recorded and auditable. Extend `@subscription_types` (one module
  attribute) when HubSpot publishes new types.

  The optional secret callbacks are deliberately NOT implemented: HubSpot
  signs with the app-wide client secret — supply it through the DSL
  `secret` source. `timestamp_header/0` IS implemented (the replay window
  hangs off it).
  """

  alias AshHooks.Provider

  defmodule Event do
    @moduledoc "Typed event echoed by `AshHooks.Provider.HubSpotV3.handle_event/2`."

    defstruct [:type, :payload]

    @type t :: %__MODULE__{type: atom(), payload: map() | list()}
  end

  @behaviour Provider

  @timestamp_header "x-hubspot-request-timestamp"
  @vendor_default_window_seconds 300

  # The vendor's documented requestUri decode map (validation guide,
  # 2026-08-21). Lower-case percent-hex decodes the same — RFC 3986
  # percent-encoding is case-insensitive.
  @uri_decode %{
    "%3A" => ":",
    "%2F" => "/",
    "%3F" => "?",
    "%40" => "@",
    "%21" => "!",
    "%24" => "$",
    "%27" => "'",
    "%28" => "(",
    "%29" => ")",
    "%2A" => "*",
    "%2C" => ",",
    "%3B" => ";"
  }

  # Vendor-documented taxonomy (webhooks guide, verified first-hand
  # 2026-08-21; a strict superset of the reference platform adapter's
  # production set — 9/9). The guide's field table notes some example
  # payloads name the field `eventType`; the signed vector on the
  # validation page and the incumbent's production wire both carry
  # `subscriptionType`, which is what this map keys on.
  @subscription_types %{
    "contact.creation" => :contact_creation,
    "contact.deletion" => :contact_deletion,
    "contact.merge" => :contact_merge,
    "contact.associationChange" => :contact_association_change,
    "contact.restore" => :contact_restore,
    "contact.privacyDeletion" => :contact_privacy_deletion,
    "contact.propertyChange" => :contact_property_change,
    "company.creation" => :company_creation,
    "company.deletion" => :company_deletion,
    "company.propertyChange" => :company_property_change,
    "company.associationChange" => :company_association_change,
    "company.restore" => :company_restore,
    "company.merge" => :company_merge,
    "deal.creation" => :deal_creation,
    "deal.deletion" => :deal_deletion,
    "deal.associationChange" => :deal_association_change,
    "deal.restore" => :deal_restore,
    "deal.merge" => :deal_merge,
    "deal.propertyChange" => :deal_property_change,
    "ticket.creation" => :ticket_creation,
    "ticket.deletion" => :ticket_deletion,
    "ticket.propertyChange" => :ticket_property_change,
    "ticket.associationChange" => :ticket_association_change,
    "ticket.restore" => :ticket_restore,
    "ticket.merge" => :ticket_merge,
    "product.creation" => :product_creation,
    "product.deletion" => :product_deletion,
    "product.restore" => :product_restore,
    "product.merge" => :product_merge,
    "product.propertyChange" => :product_property_change,
    "line_item.creation" => :line_item_creation,
    "line_item.deletion" => :line_item_deletion,
    "line_item.associationChange" => :line_item_association_change,
    "line_item.restore" => :line_item_restore,
    "line_item.merge" => :line_item_merge,
    "line_item.propertyChange" => :line_item_property_change,
    "conversation.creation" => :conversation_creation,
    "conversation.deletion" => :conversation_deletion,
    "conversation.privacyDeletion" => :conversation_privacy_deletion,
    "conversation.propertyChange" => :conversation_property_change,
    "conversation.newMessage" => :conversation_new_message
  }

  @impl Provider
  def verify_signature(_raw_body, _ctx, secret)
      when is_binary(secret) and byte_size(secret) == 0,
      do: {:error, :no_webhook_secret}

  def verify_signature(raw_body, ctx, secret)
      when is_binary(raw_body) and is_map(ctx) and is_binary(secret) do
    with {:ok, timestamp_ms} <- fetch_timestamp(ctx),
         :ok <- check_replay_window(ctx, timestamp_ms),
         {:ok, source} <- canonical_string(raw_body, ctx, timestamp_ms) do
      expected = Base.encode64(:crypto.mac(:hmac, :sha256, secret, source))

      if byte_size(expected) == byte_size(ctx.signature) and
           :crypto.hash_equals(expected, ctx.signature) do
        :ok
      else
        {:error, :invalid_signature}
      end
    end
  end

  def verify_signature(_raw_body, _ctx, _secret), do: {:error, :invalid_signature}

  @impl Provider
  def parse_event_type(payload) when is_list(payload) and payload != [] do
    case batch_types(payload, MapSet.new()) do
      {:ok, types} ->
        case MapSet.to_list(types) do
          [single] -> {:ok, single}
          _mixed -> {:ok, :mixed}
        end

      {:error, _reason} = error ->
        error
    end
  end

  def parse_event_type(_payload), do: {:error, :malformed_payload}

  @impl Provider
  def handle_event(event_type, payload) do
    {:ok, %Event{type: event_type, payload: payload}}
  end

  @impl Provider
  def timestamp_header, do: @timestamp_header

  @doc """
  Decodes the vendor's documented percent-encodings in a signed request URI
  (`%3A %2F %3F %40 %21 %24 %27 %28 %29 %2A %2C %3B`, either hex case) —
  HubSpot signs the DECODED form, so the verifier must decode before
  hashing. The query-separator `?` itself is unaffected (only its encoded
  `%3F` form decodes).
  """
  @spec decode_request_uri(String.t()) :: String.t()
  def decode_request_uri(uri) when is_binary(uri) do
    Enum.reduce(@uri_decode, uri, fn {encoded, decoded}, acc ->
      acc
      |> String.replace(encoded, decoded)
      |> String.replace(String.downcase(encoded), decoded)
    end)
  end

  # Header names are case-insensitive: scan rather than fetch a lowercased
  # key, so a caller supplying Plug-raw or mixed-case headers still
  # verifies. Only single binary values count — a multi-value list is
  # skipped and the header treated as missing (fail closed).
  defp fetch_timestamp(%{headers: headers}) when is_map(headers) do
    headers
    |> Enum.find_value(fn
      {name, value} when is_binary(name) and is_binary(value) and value != "" ->
        if String.downcase(name) == @timestamp_header, do: value

      _other ->
        nil
    end)
    |> case do
      nil -> {:error, :invalid_signature}
      timestamp -> parse_timestamp(timestamp)
    end
  end

  defp fetch_timestamp(_ctx), do: {:error, :invalid_signature}

  # Milliseconds since epoch — a full-string non-negative integer. Anything
  # else cannot be windowed or signed, so it fails closed as an invalid
  # signature (the header is part of the scheme).
  defp parse_timestamp(timestamp) do
    case Integer.parse(timestamp) do
      {timestamp_ms, ""} when timestamp_ms >= 0 -> {:ok, timestamp_ms}
      _other -> {:error, :invalid_signature}
    end
  end

  # The vendor's validation step 1, enforced with the vendor's own default
  # when the DSL is silent: reject a timestamp OLDER than the window.
  # One-sided past-only — both vendor samples compare
  # `currentTime - timestamp > max`; a future timestamp is signature-bound
  # and enables no replay.
  defp check_replay_window(ctx, timestamp_ms) do
    window_seconds = ctx[:replay_window_seconds] || @vendor_default_window_seconds
    now_ms = ctx[:now_ms] || System.system_time(:millisecond)

    if now_ms - timestamp_ms > window_seconds * 1000 do
      {:error, :stale_timestamp}
    else
      :ok
    end
  end

  defp canonical_string(raw_body, ctx, timestamp_ms) do
    case {ctx[:method], ctx[:request_uri]} do
      {method, uri} when is_binary(method) and is_binary(uri) ->
        {:ok, method <> decode_request_uri(uri) <> raw_body <> Integer.to_string(timestamp_ms)}

      _missing ->
        {:error, :invalid_signature}
    end
  end

  defp batch_types([], types), do: {:ok, types}

  defp batch_types([%{"subscriptionType" => raw} | rest], types)
       when is_binary(raw) do
    case Map.fetch(@subscription_types, raw) do
      {:ok, type} -> batch_types(rest, MapSet.put(types, type))
      :error -> {:error, :unknown_event_type}
    end
  end

  defp batch_types([_non_event | _rest], _types), do: {:error, :malformed_payload}
end
