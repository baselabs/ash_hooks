defmodule AshHooks.Provider.EasyPost do
  @moduledoc """
  Verifies EasyPost's v1 and v2 webhook signatures following its [Webhook API documentation](https://docs.easypost.com/docs/webhooks#webhook-authentication)
  and official [Python `validate_webhook` implementation](https://github.com/EasyPost/easypost-python/blob/7e788d1b92272bbe4e899eab5c923e53f13df778/easypost/util.py#L118-L144).

  For v1, pass `X-Hmac-Signature` in `ctx.signature`. It must be
  `hmac-sha256-hex=<lowercase hex HMAC-SHA256 of the raw body>`. The key is the
  webhook's `webhook_secret`, Unicode NFKD-normalized and UTF-8 encoded before
  hashing, matching the official Python and [Ruby client](https://github.com/EasyPost/easypost-ruby/blob/16d18a4121be61f9e428f4a45e01c6e2f4a6b4b8/lib/easypost/util.rb#L159-L175).
  Only the secret is normalized; request bytes stay unchanged. The prefix and
  digest are case-sensitive, as in those clients. Comparisons use constant time
  behind an equal-length guard. Ingress's `previous_secret` resolver supports
  overlapping keys with the same normalization applied to each key.

  For v2, the separate
  [HMAC help article](https://support.easypost.com/hc/en-us/articles/39826034964237-Webhook-HMAC-Validation)
  specifies `x-timestamp` (RFC 2822 with numeric timezone), `x-path`, and
  `x-hmac-signature-v2` (`hmac-sha256-hex=<hex>`). Pass all three in `ctx.headers`,
  the v2 signature in `ctx.signature`, the uppercase HTTP method in `ctx.method`,
  and the independently known public path in `ctx.request_uri`. The path must
  exactly equal `x-path`; it is never inferred from that header. The host already
  supplies this value through `AshHooks.Ingress.ingest/4`; use `conn.request_path`
  when it preserves the public path, or resolve the public path from trusted host
  configuration when a proxy rewrites it. Preserve any signed encoding/query
  bytes exactly; no URL reconstruction, decoding, or normalization is applied.

  V2 signs `timestamp <> method <> path <> raw_body` without separators, using
  HMAC-SHA256, UTF-8 secret bytes as supplied (v2 specifies no NFKD step), and
  case-insensitive hex/prefix comparison. It uses the article's default maximum
  age of 60 seconds and future allowance of 30 seconds. A present v2 header is
  authoritative, including when malformed or stale: it never falls back to v1.
  Both versions support ingress's `previous_secret` overlap.

  The public API/docs and current Python, Ruby, Node, and Go validators still
  describe v1; they do not establish whether v2 replaces v1, both are delivered,
  or an account/webhook can opt in. This verifier implements the documented v2
  envelope without claiming live delivery or rollout proof. Because v1 remains
  accepted and has no signed timestamp, this module keeps `timestamp_header/0`
  undeclared. Use durable deduplication, not DSL `replay_window_seconds`.

  Returns `AshHooks.Provider.Event`; wrap it for application event classification
  and idempotent business actions.
  """

  @behaviour AshHooks.Provider
  alias AshHooks.Provider.{Event, Signature}

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
  @weekdays ~w(Mon Tue Wed Thu Fri Sat Sun)
  @timestamp ~r/\A(Mon|Tue|Wed|Thu|Fri|Sat|Sun), ([0-9]{1,2}) ([A-Za-z]{3}) ([0-9]{4}) ([0-9]{2}):([0-9]{2}):([0-9]{2}) ([+-])([0-9]{2})([0-9]{2})\z/

  @impl true
  def verify_signature(_body, _ctx, secret) when not is_binary(secret) or secret == "",
    do: {:error, :no_webhook_secret}

  def verify_signature(body, ctx, secret) when is_binary(body) and is_map(ctx) do
    case v2_header(ctx) do
      nil -> verify_v1(body, ctx, secret)
      {_name, signature} -> verify_v2(body, ctx, signature, secret)
    end
  end

  def verify_signature(_body, _ctx, _secret), do: {:error, :invalid_signature}

  # Presence matters: even an empty/non-binary v2 header must prevent fallback.
  defp v2_header(%{headers: headers}) when is_map(headers) do
    Enum.find(headers, fn {name, _value} ->
      is_binary(name) and String.downcase(name) == "x-hmac-signature-v2"
    end)
  end

  defp v2_header(_ctx), do: nil

  defp verify_v1(body, %{signature: "hmac-sha256-hex=" <> mac}, secret) do
    case :unicode.characters_to_nfkd_binary(secret) do
      key when is_binary(key) -> Signature.hmac(body, mac, key, :sha256, :hex)
      _ -> {:error, :invalid_signature}
    end
  end

  defp verify_v1(_body, _ctx, _secret), do: {:error, :invalid_signature}

  defp verify_v2(body, ctx, signature, secret) do
    with true <- is_binary(signature) and byte_size(signature) == 80,
         "hmac-sha256-hex=" <> mac <- String.downcase(signature, :ascii),
         true <- String.valid?(secret),
         timestamp when is_binary(timestamp) <- Signature.header(ctx, "x-timestamp"),
         path when is_binary(path) <- Signature.header(ctx, "x-path"),
         true <- String.starts_with?(path, "/") and path == ctx[:request_uri],
         method when is_binary(method) and method != "" <- ctx[:method],
         true <- Regex.match?(~r/\A[A-Z]+\z/, method),
         :ok <- Signature.hmac(timestamp <> method <> path <> body, mac, secret, :sha256, :hex),
         {:ok, seconds} <- timestamp_seconds(timestamp) do
      now = div(ctx[:now_ms] || System.system_time(:millisecond), 1_000)
      if (now - seconds) in -30..60, do: :ok, else: {:error, :stale_timestamp}
    else
      _ -> {:error, :invalid_signature}
    end
  end

  defp timestamp_seconds(timestamp) do
    with true <- String.valid?(timestamp),
         [_, weekday, day, month, year, hour, minute, second, sign, tz_hour, tz_minute] <-
           Regex.run(@timestamp, timestamp),
         month_index when is_integer(month_index) <- Enum.find_index(@months, &(&1 == month)),
         {:ok, date} <- Date.new(String.to_integer(year), month_index + 1, String.to_integer(day)),
         true <- Enum.at(@weekdays, Date.day_of_week(date) - 1) == weekday,
         {:ok, time} <-
           Time.new(String.to_integer(hour), String.to_integer(minute), String.to_integer(second)),
         offset_hour = String.to_integer(tz_hour),
         offset_minute = String.to_integer(tz_minute),
         true <- offset_hour < 24 and offset_minute < 60,
         {:ok, datetime} <- DateTime.new(date, time) do
      offset = (offset_hour * 3_600 + offset_minute * 60) * if(sign == "-", do: -1, else: 1)
      {:ok, DateTime.to_unix(datetime) - offset}
    else
      _ -> {:error, :invalid_signature}
    end
  end

  @impl true
  defdelegate parse_event_type(payload), to: Event, as: :parse
  @impl true
  defdelegate handle_event(type, payload), to: Event, as: :build
end
