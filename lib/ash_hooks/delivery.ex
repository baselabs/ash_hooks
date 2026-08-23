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

    * 2xx → `:succeeded` (status + allowlisted content-type summary — NO
      body bytes by default; a per-call `snippet_capture: true` config
      persists the floor-redacted body marked `[captured]`, ADR-0005's
      snippet amendment)
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

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshHooks.Errors.Unknown.UnknownError
  alias AshHooks.Signing

  # The ADR-0005 snippet floor (amended 2026-08-22): markers are
  # case-blind (NFKC folds homoglyphs, never case) and tolerate ≤3
  # separator chars at EVERY internal juncture — the split-token evasion
  # class ("whs-ec_…", "wh-sk_…", "whs.ec …", form-encoded "Bearer+…").
  # The entropy rule dies on any ≥16-char union-alphabet run — markerless
  # base32/hex/base64url material. Bearer keeps its own dot-bearing
  # material class (JWT separators).
  @redaction_patterns [
    ~r/w[\s._+\-]{0,3}h[\s._+\-]{0,3}(?:s[\s._+\-]{0,3}(?:e[\s._+\-]{0,3}c|k)|p[\s._+\-]{0,3}k)[\s._+\-]{0,3}[A-Za-z0-9+\/%=_\-]+/i,
    ~r/Bearer[\s._+\-]{0,3}[A-Za-z0-9._\-%]+/i,
    ~r/[A-Za-z0-9+\/=%_\-]{16,}/
  ]

  @snippet_max 2_048
  @captured_prefix "[captured] "
  @binary_placeholder "[binary]"
  @summary_max 120
  # the decode chain runs as a bounded fixpoint: a JSON \u0025 escape can
  # materialize "%" only AFTER the percent layers have run, so one linear
  # pass is not closed under composition — re-decode until stable
  @decode_passes 8

  # the ONLY content-type tokens summarize/1 may ever emit besides "other"
  @content_type_allowlist MapSet.new([
                            "application/json",
                            "application/xml",
                            "text/xml",
                            "text/html",
                            "text/plain",
                            "text/csv",
                            "text/event-stream",
                            "text/javascript",
                            "application/javascript",
                            "application/x-ndjson",
                            "application/x-www-form-urlencoded",
                            "application/octet-stream"
                          ])

  @doc """
  Retention hook: deletes TERMINAL delivery rows (`:succeeded`,
  `:dead_letter`) older than `older_than`, by the resource's
  `inserted_at` (add Ash `timestamps()` to the resource and its
  migration). Non-terminal rows are never deleted. Returns
  `{:ok, deleted_count}`, or `{:error, error}` when the resource lacks
  `inserted_at` — the same error contract as `AshHooks.Ingress.prune/2`.
  """
  @spec prune(module(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def prune(deliv_mod, opts) do
    older_than = DateTime.truncate(Keyword.fetch!(opts, :older_than), :microsecond)

    if ResourceInfo.attribute(deliv_mod, :inserted_at) do
      prune!(deliv_mod, older_than)
    else
      {:error,
       UnknownError.exception(
         error:
           inspect(deliv_mod) <>
             " has no :inserted_at — add `timestamps()` to its attributes " <>
             "(and the columns to its migration) to use the retention hooks"
       )}
    end
  end

  defp prune!(deliv_mod, older_than) do
    require Ash.Query

    result =
      deliv_mod
      |> Ash.Query.filter(status in [:succeeded, :dead_letter] and inserted_at < ^older_than)
      |> Ash.bulk_destroy(:prune, %{},
        authorize?: false,
        return_records?: true,
        return_errors?: true,
        strategy: [:atomic]
      )

    case result do
      %Ash.BulkResult{status: :success, records: rows} -> {:ok, length(rows)}
      %Ash.BulkResult{errors: [error | _]} -> {:error, error}
    end
  end

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
    :telemetry.execute(
      [:ash_hooks, :delivery, :attempt],
      %{},
      %{endpoint_id: endpoint.id, event_uuid: row.event_uuid, attempts: row.attempts}
    )

    adapter = config[:http] || AshHooks.Http.Bounded

    request = if is_function(adapter, 5), do: adapter, else: &adapter.request/5

    # adapter opts seam (test listeners' validate_destination: false; real
    # consumers' timeout overrides and a pinned :cacerts trust bundle for
    # private-CA endpoints). Consumer-trusted config like :ssrf_check: it
    # CAN disable the adapter's destination pin — the driver's send-time
    # check above is the residual guarantee, not a full replacement
    adapter_opts = config[:http_opts] || []

    with {:ok, headers} <- signing_headers(row, endpoint, config),
         {:ok, response} <-
           send_request(request, endpoint, headers, row, adapter_opts) do
      record(row, endpoint, response, config)
    else
      # a pin-time SSRF refusal is a caught rebinding flip — terminal, per
      # the classification table (never burn the retry ceiling on it)
      {:error, :unsafe_destination} ->
        dead_letter(row, "unsafe_destination", config)

      {:error, reason} ->
        retry(row, error_string(reason), config, nil)
    end
  end

  # an adapter RAISE must not crash the job out of the row-owned policy —
  # classify it as a retryable transport failure (cross-vendor finding)
  defp send_request(request, endpoint, headers, row, adapter_opts) do
    request.(:post, endpoint.url, headers, row.payload, adapter_opts)
  rescue
    reason -> {:error, {:adapter_crash, error_string(reason)}}
  end

  defp record(row, _endpoint, %{status: status} = response, config)
       when status in 200..299 do
    mark_succeeded(row, response, config)
  end

  defp record(row, endpoint, %{status: 410} = response, config) do
    # the durable disable is the circuit breaker — a failed write must NOT
    # be swallowed behind the row's dead-letter (cross-vendor finding):
    # surface the error so the job retries and the 410 is re-processed
    result =
      config[:endpoints]
      |> Ash.Query.filter(id == ^endpoint.id)
      |> Ash.bulk_update(:disable, %{}, authorize?: false, return_errors?: true)

    case result do
      %Ash.BulkResult{status: :success} ->
        :telemetry.execute(
          [:ash_hooks, :delivery, :disable],
          %{},
          %{endpoint_id: endpoint.id, reason: :gone_410}
        )

        dead_letter(row, "gone_410", config, failure_summary(response))

      other ->
        {:error, {:disable_failed, other}}
    end
  end

  defp record(row, _endpoint, %{status: status} = response, config)
       when status in [408, 429] do
    retry(row, "http_#{status}", config, retry_after(response, config), failure_summary(response))
  end

  defp record(row, _endpoint, %{status: status} = response, config)
       when status in 300..399 do
    dead_letter(row, "redirect_refused_#{status}", config, failure_summary(response))
  end

  defp record(row, _endpoint, %{status: status} = response, config)
       when status in 400..499 do
    dead_letter(row, "http_#{status}", config, failure_summary(response))
  end

  defp record(row, _endpoint, %{status: status} = response, config) do
    retry(row, "http_#{status}", config, nil, failure_summary(response))
  end

  # failed rows keep the story-1 half of the snippet policy: status + kind,
  # never body bytes (the #17 design note's D6b)
  defp failure_summary(response),
    do: {response[:status], summarize(response[:status], response[:headers])}

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
           response_snippet: snippet_for(response, config)
         }) do
      {:ok, _} ->
        :telemetry.execute(
          [:ash_hooks, :delivery, :result],
          %{},
          %{
            endpoint_id: row.endpoint_id,
            event_uuid: row.event_uuid,
            status: :succeeded,
            response_status: response.status,
            reason: nil
          }
        )

        :ok

      {:error, reason} ->
        {:error, {:reconcile_failed, reason}}
    end
  end

  defp retry(row, error, config, retry_after, summary \\ nil) do
    if row.attempts >= config[:max_attempts] do
      dead_letter(row, error, config, summary)
    else
      delay = delay_seconds(row, config, retry_after)
      next_at = DateTime.add(now(config), delay, :second)

      case gated_update(
             row,
             config,
             :mark_send_failed,
             summary_input(summary, %{
               error: error,
               next_attempt_at: next_at,
               dead_letter?: false
             })
           ) do
        {:ok, _} ->
          emit_result(row, summary, :failed_retryable, error)

          :telemetry.execute(
            [:ash_hooks, :delivery, :backoff],
            %{},
            %{
              endpoint_id: row.endpoint_id,
              event_uuid: row.event_uuid,
              attempts: row.attempts,
              delay_seconds: delay
            }
          )

          {:snooze, delay}

        {:error, reason} ->
          {:error, {:reconcile_failed, reason}}
      end
    end
  end

  defp dead_letter(row, error, config, summary \\ nil) do
    case gated_update(
           row,
           config,
           :mark_send_failed,
           summary_input(summary, %{error: error, next_attempt_at: nil, dead_letter?: true}),
           # dead-letter can land from any pre-send or mid-send state —
           # including :enqueue_failed rows the runtime re-drove — never
           # from a terminal row
           [:pending, :sending, :failed_retryable, :enqueue_failed]
         ) do
      {:ok, _} ->
        emit_result(row, summary, :dead_letter, error)

        :telemetry.execute(
          [:ash_hooks, :delivery, :dead_letter],
          %{},
          %{
            endpoint_id: row.endpoint_id,
            event_uuid: row.event_uuid,
            reason: error,
            response_status: summary_status(summary)
          }
        )

        :ok

      {:error, reason} ->
        {:error, {:reconcile_failed, reason}}
    end
  end

  defp emit_result(row, summary, status, reason) do
    :telemetry.execute(
      [:ash_hooks, :delivery, :result],
      %{},
      %{
        endpoint_id: row.endpoint_id,
        event_uuid: row.event_uuid,
        status: status,
        response_status: summary_status(summary),
        reason: reason
      }
    )
  end

  defp summary_status({status, _snippet}), do: status
  defp summary_status(nil), do: nil

  # a response-derived summary rides the failure write when the attempt
  # actually saw a response; pre-send failures (disabled endpoint, SSRF
  # refusal, transport errors) write nils
  defp summary_input(nil, base),
    do: Map.merge(base, %{response_status: nil, response_snippet: nil})

  defp summary_input({status, snippet}, base),
    do: Map.merge(base, %{response_status: status, response_snippet: snippet})

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

  # ────────────────────────── snippets + redaction ──────────────────────────

  @doc """
  The DEFAULT response-snippet summary (ADR-0005's 2026-08-22 amendment):
  a fixed grammar over the status and one ALLOWLISTED content-type token —
  never body bytes, never a body-derived digest (a hash is correlation
  material that explains nothing).

      "200 json token=application/json"   # the type was allowlisted
      "200 text token=other"              # anything else collapses to other

  The status is an integer, the kind comes from a fixed vocabulary
  (`json | html | text | xml | binary | other`), and the token is either an
  exact allowlist member or the literal `other` — a hostile Content-Type
  header cannot smuggle material into the ledger through this string.
  """
  @spec summarize(integer() | nil, keyword() | list() | nil) :: String.t()
  def summarize(status, headers) do
    type = content_type(headers)
    kind = content_kind(type)
    token = if allowlisted_content_type?(type), do: type, else: "other"

    "#{status_string(status)} #{kind} token=#{token}"
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
    |> String.slice(0, @summary_max)
  end

  @doc """
  The package snippet floor (ADR-0005, amended 2026-08-22) — what
  opt-in-captured bodies pass through before persistence: NFKC
  normalization (fullwidth homoglyph markers fold), a bounded-fixpoint
  decode chain (percent ×2 + JSON \\u per-escape, re-run until stable — a
  `\\u0025` escape can materialize `%` only after the percent layers), the
  separator-tolerant marker patterns, the ≥16-char union-alphabet entropy
  rule, a control-byte strip, and the 2048 cap. Un-redaction is impossible
  by construction; invalid UTF-8 collapses to `[binary]`.
  """
  @spec redact(term()) :: String.t() | nil
  def redact(body) when is_binary(body) do
    if String.valid?(body) do
      body
      |> decode_fixpoint(@decode_passes)
      |> apply_redaction_patterns()
      # strip control bytes — a hostile NUL would make the post-send
      # ledger write fail on TEXT columns AFTER a successful send
      # (cross-vendor finding: re-send poison loop)
      |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
      |> String.replace(~r/[\r\n]+/, " ")
      |> String.slice(0, @snippet_max)
    else
      @binary_placeholder
    end
  end

  def redact(_other), do: nil

  # which snippet a reconciled row persists: the no-body summary by
  # default, the marked floor-redacted body on the per-call opt-in
  defp snippet_for(response, config) do
    body = response[:body]

    if config[:snippet_capture] && is_binary(body) do
      captured_snippet(body, response, config)
    else
      summarize(response[:status], response[:headers])
    end
  end

  defp captured_snippet(body, response, config) do
    case apply_snippet_redactor(body, config[:snippet_redactor]) do
      {:ok, material} ->
        # the combined string re-sliced so the 2048 attribute constraint
        # holds WITH the marker inside it
        String.slice(@captured_prefix <> redact(material), 0, @snippet_max)

      :sanitize ->
        # crash / invalid / nil callback return: the sanitized summary —
        # no marker (it promises captured material exists; here none does)
        summarize(response[:status], response[:headers])
    end
  end

  # The consumer callback ({m, f} | fun, like :secret_resolver) sees the
  # RAW body — consumer tokens need raw input — and its output is
  # type-checked, size-bounded, and caught (raise/exit/throw): a broken
  # callback can never poison the send or leak past the floor.
  defp apply_snippet_redactor(body, nil), do: {:ok, body}

  defp apply_snippet_redactor(body, redactor) do
    case redactor_fun(redactor).(body) do
      out when is_binary(out) -> {:ok, String.slice(out, 0, @snippet_max)}
      nil -> :sanitize
      _other -> :sanitize
    end
  catch
    :error, _reason -> :sanitize
    :exit, _reason -> :sanitize
    :throw, _value -> :sanitize
  end

  defp redactor_fun({m, f}) when is_atom(m) and is_atom(f), do: &apply(m, f, [&1])
  defp redactor_fun(fun) when is_function(fun, 1), do: fun

  # ── the floor's decode chain ──
  # One pass: percent (×2 — double-encoded disguises) → JSON \u unescape →
  # NFKC. The pass re-runs until stable: json_unescape can produce % that
  # the percent step must then decode (probed composed evasion), and NFKC
  # must see every decoded layer (a percent-encoded fullwidth marker
  # materializes only after decoding). Each pass strictly shrinks encoded
  # material; the bound is the brake.
  defp decode_fixpoint(body, 0), do: body

  defp decode_fixpoint(body, passes) do
    decoded =
      body
      |> decode_step(&URI.decode/1)
      |> decode_step(&URI.decode/1)
      |> decode_step(&json_unescape/1)
      |> normalize_step()

    if decoded == body, do: body, else: decode_fixpoint(decoded, passes - 1)
  end

  # a decode that would MATERIALIZE invalid UTF-8 ("%FF"-class escapes)
  # is refused — the floor's output must never fail the ledger's TEXT
  # write post-send (the re-send poison class; cross-vendor finding)
  defp decode_step(input, decoder) do
    case decoder.(input) do
      decoded when is_binary(decoded) -> if String.valid?(decoded), do: decoded, else: input
    end
  end

  # NFKC folds fullwidth homoglyphs (ｗｈｓｅｃ → whsec) and leaves ordinary
  # Cyrillic prose untouched (probed); invalid UTF-8 falls back to the
  # input — the patterns and entropy rule still run over it
  defp normalize_step(body), do: :unicode.characters_to_nfkc_binary(body)

  # per-escape fallback: a surrogate/high escape must not abort the whole
  # replace (that would fail the LAYER open and let a co-resident disguise
  # survive — cross-vendor probe)
  defp json_unescape(string) do
    Regex.replace(~r/\\u([0-9a-fA-F]{4})/, string, &escape_to_char/2)
  end

  defp escape_to_char(whole, code) do
    <<String.to_integer(code, 16)::utf8>>
  rescue
    ArgumentError -> whole
  end

  defp apply_redaction_patterns(body) do
    Enum.reduce(@redaction_patterns, body, &String.replace(&2, &1, "[redacted]"))
  end

  # ── summarize's fixed vocabulary ──

  defp status_string(status) when is_integer(status), do: Integer.to_string(status)
  defp status_string(_nil_or_other), do: "0"

  # Bounded downcases header names; other adapters may not — retry_after's
  # dual-keyfind precedent
  defp content_type(headers) when is_list(headers) do
    case List.keyfind(headers, "content-type", 0) || List.keyfind(headers, "Content-Type", 0) do
      {_name, value} when is_binary(value) ->
        value |> String.split(";") |> hd() |> String.trim() |> String.downcase()

      _missing ->
        nil
    end
  end

  defp content_type(_other), do: nil

  defp allowlisted_content_type?(nil), do: false
  defp allowlisted_content_type?(type), do: MapSet.member?(@content_type_allowlist, type)

  defp content_kind(nil), do: :other

  defp content_kind(type) do
    cond do
      String.contains?(type, "json") -> :json
      String.contains?(type, "html") -> :html
      String.contains?(type, "xml") -> :xml
      String.starts_with?(type, "text/") -> :text
      binary_type?(type) -> :binary
      true -> :other
    end
  end

  defp binary_type?(type) do
    String.contains?(type, "octet-stream") or
      String.starts_with?(type, "image/") or
      String.starts_with?(type, "audio/") or
      String.starts_with?(type, "video/") or
      String.starts_with?(type, "application/")
  end

  # Classify without contents (the dispatcher's rule — an arbitrary
  # consumer adapter/resolver term can carry secret or body material):
  # atoms are our own vocabulary; binaries pass only in the fixed error
  # grammar; everything else collapses to "unclassified". This is BOTH
  # the telemetry floor and the last_error ledger floor (#11 R1).
  defp error_string({:secret_resolution, _reason}), do: "secret_resolution"
  defp error_string({:adapter_crash, _inner}), do: "adapter_crash"

  defp error_string(term), do: AshHooks.Telemetry.classify_token(term)
end
