defmodule AshHooks.Delivery do
  @moduledoc """
  The delivery runtime driver: one pending delivery row → signed HTTP
  send → reconciled ledger row. Pure functions over the consumer's
  resource modules and an injected HTTP adapter — Oban-free by
  construction; `use AshHooks.Worker` wraps this as an Oban worker inside
  the consuming app (ADR-0004's host-injection boundary).

  The delivery ROW is the single retry-policy source (ADR-0008): the
  driver refuses to re-send `:succeeded`/`:dead_letter` rows, waits on
  `next_attempt_at`, counts `attempts` against the ceiling, and honors
  `Retry-After` (bounded). Oban is the durable TRIGGER — `{:snooze, s}`
  re-drives later without exhausting the job (snooze extends
  max_attempts; only this module's ceiling decides dead-letter).

  Classification (the design note's table, one source):

    * 2xx → `:succeeded` (response recorded, snippet redacted)
    * 408/429 → retryable, `Retry-After` when present (integer seconds or
      HTTP-date; clamped `[1, retry_after_cap]`), else backoff
    * 410 → endpoint durably `:disable`d + row `:dead_letter`
    * other 4xx → `:dead_letter` (client errors do not self-heal)
    * 3xx → `:dead_letter` (`redirect_refused` — never followed)
    * 5xx / transport error / secret-resolution failure → retryable
      backoff
    * send-time SSRF refusal / disabled-or-gone endpoint → `:dead_letter`

  Backoff: `min(base · 2^min(attempts, 16), max_backoff)` seconds plus
  `:rand.uniform(delay)` jitter, re-clamped — always ≥ 1 second.
  """

  require Ash.Query

  alias AshHooks.Signing

  @redaction_patterns [
    ~r/wh(sec|sk|pk)_[A-Za-z0-9+\/=]+/,
    ~r/Bearer\s+[A-Za-z0-9._\-]+/,
    ~r/[A-Za-z0-9+\/=]{20,}/,
    # percent-encoded disguises (derisk: "whsec%5F..." / "%77hsec_" forms)
    ~r/wh(sec|sk|pk)(%5[fF])?[A-Za-z0-9+\/=%]+/,
    ~r/Bearer(%20|\+|%2[00])?[A-Za-z0-9._\-%]+/,
    ~r/[A-Za-z0-9+\/=%]{24,}/
  ]

  @snippet_max 2_048

  @doc """
  Drives one delivery (args: `%{"endpoint_id" => ..., "event_uuid" => ...}`,
  string keys — Oban's JSON round-trip shape; atom keys tolerated).

  Returns `:ok` (terminal or attempted-to-terminal), `{:snooze, seconds}`
  (retry later), or `{:error, term}` for a broken trigger (row missing →
  `:ok`; the durable row is the record — a missing row is a completed or
  reaped delivery, not a failure).
  """
  @spec run(map(), keyword()) :: :ok | {:snooze, pos_integer()} | {:error, term()}
  def run(args, config) when is_map(args) do
    endpoint_id = key(args, :endpoint_id)
    event_uuid = key(args, :event_uuid)

    case fetch_row(config[:deliveries], endpoint_id, event_uuid) do
      {:ok, row} ->
        case row.status do
          status when status in [:succeeded, :dead_letter] -> :ok
          :failed_retryable -> maybe_wait(row, config)
          _attemptable -> attempt(row, config)
        end

      :missing ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp key(args, name) do
    value = Map.get(args, Atom.to_string(name)) || Map.get(args, name)
    value && to_string(value)
  end

  defp fetch_row(deliv_mod, endpoint_id, event_uuid)
       when is_binary(endpoint_id) and is_binary(event_uuid) do
    deliv_mod
    |> Ash.Query.filter(endpoint_id == ^endpoint_id and event_uuid == ^event_uuid)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> :missing
      {:ok, row} -> {:ok, row}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_row(_deliv_mod, _nil_id, _uuid), do: :missing

  # ────────────────────────── gating ──────────────────────────

  defp maybe_wait(row, config) do
    now = now(config)

    if row.next_attempt_at && DateTime.compare(row.next_attempt_at, now) == :gt do
      {:snooze, clamp_snooze(DateTime.diff(row.next_attempt_at, now, :second))}
    else
      attempt(row, config)
    end
  end

  defp attempt(row, config) do
    case Ash.get(config[:endpoints], row.endpoint_id, authorize?: false) do
      {:ok, %{status: :disabled}} ->
        dead_letter(row, "endpoint_disabled", config)

      {:ok, endpoint} ->
        attempt_enabled(row, endpoint, config)

      # only a GONE endpoint row is terminal — a transient read error must
      # retry, never permanently dead-letter (cross-vendor finding)
      {:error, %Ash.Error.Invalid{errors: reasons}} = error ->
        if Enum.all?(reasons, &is_struct(&1, Ash.Error.Query.NotFound)) do
          dead_letter(row, "endpoint_gone", config)
        else
          {:error, error}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp attempt_enabled(row, endpoint, config) do
    # send-time re-check: full DNS re-resolution by default (ADR-0005);
    # the seam is injectable so deterministic tests use the
    # literal-only variant
    check = config[:ssrf_check] || (&AshHooks.Ssrf.safe_url?/1)

    if check.(endpoint.url) do
      case mark_sending(row, config) do
        {:ok, sending} -> send(sending, endpoint, config)
        :contended -> {:snooze, 1}
      end
    else
      dead_letter(row, "unsafe_destination", config)
    end
  end

  # ────────────────────────── the send ──────────────────────────

  defp send(row, endpoint, config) do
    adapter = config[:http] || AshHooks.Http.Httpc

    with {:ok, headers} <- signing_headers(row, endpoint, config),
         {:ok, response} <-
           adapter.request(:post, endpoint.url, headers, row.payload, []) do
      record(row, endpoint, response, config)
    else
      {:error, reason} ->
        retry(row, error_string(reason), config, nil)
    end
  end

  defp record(row, _endpoint, %{status: status} = response, config)
       when status in 200..299 do
    mark_succeeded(row, response, config)
  end

  defp record(row, endpoint, %{status: 410} = _response, config) do
    # the durable disable is the circuit breaker — a failed write must NOT
    # be swallowed behind the row's dead-letter (cross-vendor finding):
    # surface the error so the job retries and the 410 is re-processed
    result =
      config[:endpoints]
      |> Ash.Query.filter(id == ^endpoint.id)
      |> Ash.bulk_update(:disable, %{}, authorize?: false, return_errors?: true)

    case result do
      %Ash.BulkResult{status: :success} -> dead_letter(row, "gone_410", config)
      other -> {:error, {:disable_failed, other}}
    end
  end

  defp record(row, _endpoint, %{status: status} = response, config)
       when status in [408, 429] do
    retry(row, "http_#{status}", config, retry_after(response, config))
  end

  defp record(row, _endpoint, %{status: status} = _response, config)
       when status in 300..399 do
    dead_letter(row, "redirect_refused_#{status}", config)
  end

  defp record(row, _endpoint, %{status: status} = _response, config)
       when status in 400..499 do
    dead_letter(row, "http_#{status}", config)
  end

  defp record(row, _endpoint, %{status: status} = _response, config) do
    retry(row, "http_#{status}", config, nil)
  end

  # ────────────────────────── signing ──────────────────────────

  defp signing_headers(row, endpoint, config) do
    resolver = config[:secret_resolver]

    with {:ok, secret} <- resolve(endpoint.secret_ref, resolver),
         {:ok, previous} <- resolve_opt(endpoint.previous_secret_ref, resolver),
         {:ok, legacy} <- resolve_opt(endpoint.legacy_secret_ref, resolver),
         {:ok, legacy_previous} <- resolve_opt(endpoint.legacy_previous_secret_ref, resolver) do
      opts =
        sw_secret(secret)
        |> Keyword.merge(sw_previous(previous))
        |> Keyword.merge(legacy_secret(legacy, legacy_previous))

      mode = row.signing_mode || :standard

      headers =
        Signing.headers_for_mode(
          mode,
          row.event_uuid,
          System.system_time(:second),
          row.payload,
          opts
        )

      {:ok, Map.put(headers, "content-type", "application/json")}
    end
  rescue
    ArgumentError -> {:error, :signing_failed}
  end

  defp resolve(ref, {m, f}) when is_binary(ref) and ref != "" and is_atom(m) and is_atom(f) do
    resolve(ref, &apply(m, f, [&1]))
  end

  defp resolve(ref, resolver) when is_binary(ref) and ref != "" and is_function(resolver, 1) do
    case resolver.(ref) do
      {:ok, secret} when is_binary(secret) and secret != "" -> {:ok, secret}
      {:error, reason} -> {:error, {:secret_resolution, reason}}
      _other -> {:error, {:secret_resolution, :invalid_resolver_result}}
    end
  end

  defp resolve(_missing_ref, _resolver), do: {:error, :no_secret}

  defp resolve_opt(ref, resolver) when is_binary(ref) and ref != "", do: resolve(ref, resolver)
  defp resolve_opt(_nil, _resolver), do: {:ok, nil}

  # the resolved binary's prefix selects the SW option slot; unprefixed
  # material signs symmetric (v1) — the references' Signing contract
  defp sw_secret(secret), do: sw_option(:base, secret)

  defp sw_previous(nil), do: []
  defp sw_previous(secret), do: sw_option(:previous, secret)

  defp sw_option(kind, secret) do
    key =
      case {kind, String.starts_with?(secret, "whsk_")} do
        {:base, true} -> :whsk
        {:base, false} -> :whsec
        {:previous, true} -> :previous_whsk
        {:previous, false} -> :previous_whsec
      end

    [{key, secret}]
  end

  defp legacy_secret(nil, _), do: []
  defp legacy_secret(legacy, nil), do: [legacy_secret: legacy]

  defp legacy_secret(legacy, previous),
    do: [legacy_secret: legacy, legacy_previous_secret: previous]

  # ────────────────────────── transitions ──────────────────────────

  defp mark_sending(row, config) do
    result =
      gated_update(
        row,
        config,
        :mark_sending,
        %{},
        [:pending, :sending, :failed_retryable, :enqueue_failed]
      )

    case result do
      {:ok, [updated]} -> {:ok, updated}
      _none_matched -> :contended
    end
  end

  # Reconcile writes are NEVER swallowed (cross-vendor finding): with job
  # uniqueness at states: :all / period: :infinity, a lost terminal write
  # strands the row in :sending with no possible re-trigger — surface the
  # error so the job error-retries and the reconcile re-runs.
  defp mark_succeeded(row, response, config) do
    case gated_update(row, config, :mark_succeeded, %{
           response_status: response.status,
           response_snippet: redact(response[:body] || response.body)
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:reconcile_failed, reason}}
    end
  end

  defp retry(row, error, config, retry_after) do
    if row.attempts >= config[:max_attempts] do
      dead_letter(row, error, config)
    else
      delay = delay_seconds(row, config, retry_after)
      next_at = DateTime.add(now(config), delay, :second)

      case gated_update(row, config, :mark_send_failed, %{
             error: error,
             next_attempt_at: next_at,
             dead_letter?: false
           }) do
        {:ok, _} -> {:snooze, delay}
        {:error, reason} -> {:error, {:reconcile_failed, reason}}
      end
    end
  end

  defp dead_letter(row, error, config) do
    case gated_update(
           row,
           config,
           :mark_send_failed,
           %{error: error, next_attempt_at: nil, dead_letter?: true},
           # dead-letter can land from any pre-send or mid-send state —
           # including :enqueue_failed rows the runtime re-drove — never
           # from a terminal row
           [:pending, :sending, :failed_retryable, :enqueue_failed]
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:reconcile_failed, reason}}
    end
  end

  # The WHERE gate IS the fence (portable pattern): id + a status set the
  # transition legitimately starts from. :mark_sending re-drives :sending
  # (crash recovery — at-least-once, receivers dedup by webhook-id); the
  # reconcile marks are owned by the attempt that flipped to :sending.
  defp gated_update(row, config, action, input, statuses \\ [:sending]) do
    result = config[:deliveries]

    result
    |> Ash.Query.filter(id == ^row.id and status in ^statuses)
    |> Ash.bulk_update(action, input,
      authorize?: false,
      return_records?: true,
      return_errors?: true,
      strategy: [:atomic]
    )
    |> case do
      %Ash.BulkResult{status: :success, records: records} -> {:ok, records}
      %Ash.BulkResult{errors: [error | _]} -> {:error, error}
      %Ash.BulkResult{} -> {:error, {:action_failed, action}}
    end
  end

  # ────────────────────────── scheduling math ──────────────────────────

  defp delay_seconds(_row, config, retry_after) when is_integer(retry_after) do
    clamp_snooze(min(retry_after, config[:retry_after_cap_seconds]))
  end

  defp delay_seconds(row, config, _no_retry_after) do
    base = config[:base_backoff_seconds]
    max_backoff = config[:max_backoff_seconds]
    exponent = row.attempts |> min(16) |> max(0)
    step = base * Bitwise.bsl(1, exponent)

    step
    |> min(max_backoff)
    |> then(&min(&1 + :rand.uniform(max(&1, 1)) - 1, max_backoff))
    |> clamp_snooze()
  end

  defp retry_after(%{headers: headers}, config) when is_list(headers) do
    case List.keyfind(headers, "retry-after", 0) || List.keyfind(headers, "Retry-After", 0) do
      {_name, value} -> parse_retry_after(value, config)
      nil -> nil
    end
  end

  defp retry_after(_, _config), do: nil

  defp parse_retry_after(value, config) when is_binary(value) do
    trimmed = String.trim(value)

    case Integer.parse(trimmed) do
      {seconds, ""} ->
        max(seconds, 0)

      _not_integer ->
        case parse_http_date(trimmed) do
          %DateTime{} = at -> max(DateTime.diff(at, now(config), :second), 0)
          _unparseable -> nil
        end
    end
  end

  # Remote-controlled header value: ANY failure must parse to nil (backoff
  # fallback), never raise out of the driver (cross-vendor finding — bad
  # numerics in a GMT-shaped value crash the bangs).
  defp parse_http_date(string) do
    case DateTime.from_iso8601(string) do
      {:ok, dt, _offset} ->
        dt

      _rfc1123 ->
        # "Mon, 01 Jan 2026 00:00:00 GMT" — parse the fields tolerantly
        with [_wd, date, month, year, time, "GMT"] <- String.split(string, " "),
             {:ok, month_n} <- month_number(month),
             {d, ""} <- Integer.parse(date),
             {y, ""} <- Integer.parse(year),
             [h, m, s] <- parse_hms(time),
             {:ok, date_d} <- Date.new(y, month_n, d),
             {:ok, time_t} <- Time.new(h, m, s) do
          DateTime.new!(date_d, time_t, "Etc/UTC")
        else
          _malformed -> nil
        end
    end
  end

  defp parse_hms(time) do
    case Enum.map(String.split(time, ":"), &parse_int_or_nil/1) do
      [_, _, _] = parts ->
        if nil in parts, do: nil, else: parts

      _wrong_shape ->
        nil
    end
  end

  defp parse_int_or_nil(string) do
    case Integer.parse(string) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp month_number("Jan"), do: {:ok, 1}
  defp month_number("Feb"), do: {:ok, 2}
  defp month_number("Mar"), do: {:ok, 3}
  defp month_number("Apr"), do: {:ok, 4}
  defp month_number("May"), do: {:ok, 5}
  defp month_number("Jun"), do: {:ok, 6}
  defp month_number("Jul"), do: {:ok, 7}
  defp month_number("Aug"), do: {:ok, 8}
  defp month_number("Sep"), do: {:ok, 9}
  defp month_number("Oct"), do: {:ok, 10}
  defp month_number("Nov"), do: {:ok, 11}
  defp month_number("Dec"), do: {:ok, 12}
  defp month_number(_), do: :error

  defp clamp_snooze(seconds) when is_integer(seconds), do: max(seconds, 1)

  defp now(config) do
    (config[:now] || fn -> DateTime.utc_now() end).() |> DateTime.truncate(:second)
  end

  # ────────────────────────── redaction ──────────────────────────

  defp redact(body) when is_binary(body) do
    @redaction_patterns
    |> Enum.reduce(body, &String.replace(&2, &1, "[redacted]"))
    |> String.replace(~r/[\r\n]+/, " ")
    |> String.slice(0, @snippet_max)
  end

  defp redact(_other), do: nil

  defp error_string(term) when is_binary(term), do: String.slice(term, 0, 255)
  defp error_string(term) when is_atom(term), do: Atom.to_string(term)

  defp error_string(term), do: inspect(term) |> String.slice(0, 255)
end
