defmodule AshHooks.Delivery do
  @moduledoc """
  Drives one durable outbound delivery through signing, HTTP, and result
  persistence. It uses your resource modules and configured HTTP adapter.
  `AshHooks.Worker` adds an Oban trigger; this driver also works without Oban.

  The delivery row owns retry policy: the
  driver refuses to re-send `:succeeded`/`:dead_letter` rows, waits on
  `next_attempt_at`, counts `attempts` against the ceiling, and honors
  `Retry-After` (bounded). Oban is the durable trigger; `{:snooze, s}`
  re-drives later without exhausting the job (snooze extends
  max_attempts; only this module's ceiling decides dead-letter).

  Every attempt runs in an owned monitored process under one finite deadline.
  The budget includes endpoint reads, secret resolution, signing, destination
  validation, DNS/connect/HTTP work, response handling, and the result write.
  The durable send lease is derived from that deadline plus a bounded
  finalization allowance, and every result write is fenced by the row's full
  primary key, source, attempt token, sending state, and live lease.

  Lease construction and comparisons use the configured application clock
  (`:now`) or `DateTime.utc_now/0`. Deploy executors with synchronized clocks;
  clock skew can shorten or extend admission windows, so this module does not
  claim a database-clock distributed timing guarantee.

  Response classification:

    * 2xx → `:succeeded` (status + allowlisted content-type summary; no
      body bytes by default; a per-call `snippet_capture: true` config
      persists a bounded, redacted body marked `[captured]`)
    * 408/429/5xx → retryable, `Retry-After` when present (integer seconds or
      HTTP-date; clamped `[1, retry_after_cap_seconds]`), else backoff
    * 410 → `:disable_pending`, then conditional endpoint disable and `:dead_letter`
    * other 4xx → `:dead_letter` (client errors do not self-heal)
    * 3xx → `:dead_letter` (`redirect_refused`; never followed)
    * transport error / secret-resolution failure → retryable
      backoff
    * unresolvable DNS at the send-time destination check → retryable
      backoff under `nxdomain` (every family answered authoritatively
      negative) or `resolve_timeout` (resolver outage, congestion, mixed
      evidence; transport, not a verdict on the destination); a
      permanently dead domain dead-letters at the row ceiling carrying
      its label. The HTTP adapter's umbrella for the same failures is
      `unresolved_host`
    * send-time SSRF refusal / disabled-or-gone endpoint → `:dead_letter`
    * a configured `:destination_policy` decides ahead of the packaged SSRF
      gate (`AshHooks.DestinationPolicy`): `:deny` → `:dead_letter`
      (`destination_denied`), `:allow` → the send proceeds without the
      packaged gate, `:default` → the gate runs unchanged; a contained
      callback failure retries under `destination_policy_failed`

  Backoff: let `step = min(base * 2^min(attempts, 16), max_backoff)`.
  Add a random value from zero through `step - 1`, then apply the maximum
  again. The delay is at least one second.

  The 410 auto-disable is a durable two-step system write. A live attempt
  first stores `:disable_pending` with the endpoint configuration snapshot;
  recovery then conditionally disables that same configuration and finalizes
  the row. A changed endpoint is never disabled by an older 410. One
  410 disables the matching endpoint as a system action (`authorize?: false`).
  The write has no application actor and is unattributed in a versioned register.
  Without application notifications, delivery stops silently from the tenant's
  perspective. Attach `[:ash_hooks, :delivery, :disable]` to your operator or
  notification surface; it carries the tenant and endpoint IDs. The endpoint's
  status or mapped switch also exposes the durable disabled state.
  """

  require Ash.Query

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshHooks.Errors.Unknown.UnknownError
  alias AshHooks.Http.Headers
  alias AshHooks.{OutboundBinding, PrimaryKey, Signing, Tenancy}
  alias Spark.Dsl.Extension

  # The ADR-0005 snippet floor (amended 2026-08-22): markers are
  # case-blind (NFKC folds homoglyphs, never case) and tolerate ≤3
  # separator chars at EVERY internal juncture — the split-token evasion
  # class ("whs-ec_…", "wh-sk_…", "whs.ec …", form-encoded "Bearer+…").
  # The entropy rule dies on any ≥16-char union-alphabet run — markerless
  # base32/hex/base64url material. Bearer keeps its own dot-bearing
  # material class (JWT separators).
  # A defp, NOT a module attribute: an attribute's value is injected into
  # every consuming function body at compile time, and a %Regex{} carries
  # the compiled re_pattern — a reference on OTP 28, which Elixir < 1.19
  # cannot escape ("cannot inject attribute ... cannot escape
  # #Reference"). The window floor is 1.20, so that combination is
  # out-of-window today; the defp keeps the escape class dead if the
  # floor ever drops below 1.19.
  defp redaction_patterns do
    [
      ~r/w[\s._+\-]{0,3}h[\s._+\-]{0,3}(?:s[\s._+\-]{0,3}(?:e[\s._+\-]{0,3}c|k)|p[\s._+\-]{0,3}k)[\s._+\-]{0,3}[A-Za-z0-9+\/%=_\-]+/i,
      ~r/Bearer[\s._+\-]{0,3}[A-Za-z0-9._\-%]+/i,
      ~r/[A-Za-z0-9+\/=%_\-]{16,}/
    ]
  end

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
  Lists delivery rows by filter with keyset pagination (newest first) ;
  the delivery-log view behind endpoint pages and resend UIs.

  Options:

    * `:endpoint_id`; one endpoint's deliveries.
    * `:status`; a list of statuses (e.g. `[:failed_retryable, :dead_letter]`).
    * `:event_type`; one event type's deliveries.
    * `:test`; `true`/`false` on `test_tracking :on` resources: filter
      the delivery log to (or exclude) test sends.
    * `:from` / `:to`; `DateTime` bounds on `inserted_at` (inclusive).
    * `:limit`; page size (default 50, max 500; anything else is
      `{:error, :invalid_limit}`).
    * `:after`; the cursor from a previous page's `:next_cursor` (a
      malformed cursor is `{:error, :invalid_cursor}`).
    * `:tenant`; required on multitenant resources (the named
      `{:error, :tenant_required}` pre-flight otherwise).

  The resource needs `inserted_at` (add `timestamps()`) and an `:id`
  attribute (the keyset tiebreak); otherwise the call fails with the
  named error before any data access.

  Returns `{:ok, %{records: [row], next_cursor: binary | nil}}`.
  """
  @spec list(module(), keyword()) ::
          {:ok, %{records: [struct()], next_cursor: binary() | nil}} | {:error, term()}
  def list(deliv_mod, opts \\ []) do
    alias AshHooks.{Keyset, Tenancy}

    with {:ok, tenant} <- Tenancy.resolve([deliv_mod], opts[:tenant]),
         :ok <- require_list_columns(deliv_mod) do
      Keyset.read_page(deliv_mod, opts, :inserted_at, &list_filters(&1, opts), tenant)
    end
  end

  defp require_list_columns(deliv_mod) do
    cond do
      is_nil(ResourceInfo.attribute(deliv_mod, :inserted_at)) ->
        {:error,
         UnknownError.exception(
           error:
             inspect(deliv_mod) <>
               " has no :inserted_at — add `timestamps()` to its attributes " <>
               "(and the columns to its migration) to use the list queries"
         )}

      is_nil(ResourceInfo.attribute(deliv_mod, :id)) ->
        {:error,
         UnknownError.exception(
           error:
             inspect(deliv_mod) <>
               " has no :id attribute — keyset pagination's tiebreak requires it " <>
               "(composite-key ledgers are not supported by the list queries)"
         )}

      true ->
        :ok
    end
  end

  defp list_filters(query, opts) do
    query
    |> optional_list_eq(:endpoint_id, opts[:endpoint_id])
    |> optional_list_eq(:event_type, opts[:event_type])
    |> optional_list_in(:status, opts[:status])
    |> optional_list_eq(:test, opts[:test])
    |> list_time_range(opts[:from], opts[:to])
  end

  defp optional_list_eq(query, _field, nil), do: query

  defp optional_list_eq(query, field, value) do
    require Ash.Expr
    ref = Ash.Expr.ref(field)
    expression = Ash.Expr.expr(^ref == ^value)
    Ash.Query.filter(query, ^expression)
  end

  defp optional_list_in(query, _field, nil), do: query

  defp optional_list_in(query, field, values) when is_list(values) do
    require Ash.Expr
    ref = Ash.Expr.ref(field)
    expression = Ash.Expr.expr(^ref in ^values)
    Ash.Query.filter(query, ^expression)
  end

  defp list_time_range(query, nil, nil), do: query

  defp list_time_range(query, from, to) do
    require Ash.Expr
    time = Ash.Expr.ref(:inserted_at)

    lower = if from, do: Ash.Expr.expr(^time >= ^from)
    upper = if to, do: Ash.Expr.expr(^time <= ^to)

    expression =
      case {lower, upper} do
        {one, nil} -> one
        {nil, one} -> one
        {lower, upper} -> Ash.Expr.expr(^lower and ^upper)
      end

    if expression, do: Ash.Query.filter(query, ^expression), else: query
  end

  @doc """
  Retention hook: deletes TERMINAL delivery rows (`:succeeded`,
  `:dead_letter`) older than `older_than`, by the resource's
  `inserted_at` (add Ash `timestamps()` to the resource and its
  migration). Non-terminal rows are never deleted. Returns
  `{:ok, deleted_count}`, or `{:error, error}` when the resource lacks
  `inserted_at`; the same error contract as `AshHooks.Ingress.prune/2`.

  `:tenant` scopes the sweep (required on multitenant resources; a
  tenant-less global sweep over them is the named
  `{:error, :tenant_required}` before any data access).
  `:batch_size` defaults to 500 and accepts integers from 1 through 5,000;
  invalid values return `{:error, :invalid_batch_size}`.

  `:attempts` (an `AshHooks.OutboundAttempt` resource) prunes the
  pruned rows' attempt history after each delivery batch is deleted. These
  deletions are not one transaction, and history-deletion failures are ignored.
  """
  @spec prune(module(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def prune(deliv_mod, opts) do
    older_than = DateTime.truncate(Keyword.fetch!(opts, :older_than), :microsecond)

    with {:ok, tenant} <-
           Tenancy.resolve(Enum.reject([deliv_mod, opts[:attempts]], &is_nil/1), opts[:tenant]) do
      cond do
        is_nil(ResourceInfo.action(deliv_mod, :prune)) ->
          # prune_action :none (the append-only opt-out): the hook must
          # fail LOUD, never reach for an action the consumer chose not
          # to carry
          {:error,
           UnknownError.exception(
             error:
               inspect(deliv_mod) <>
                 " does not carry the destroy :prune action (prune_action :none) — " <>
                 "deletion is the consumer's own surface on an append-only ledger"
           )}

        ResourceInfo.attribute(deliv_mod, :inserted_at) ->
          prune!(deliv_mod, older_than, tenant, Keyword.get(opts, :batch_size, 500), opts)

        true ->
          {:error,
           UnknownError.exception(
             error:
               inspect(deliv_mod) <>
                 " has no :inserted_at — add `timestamps()` to its attributes " <>
                 "(and the columns to its migration) to use the retention hooks"
           )}
      end
    end
  end

  defp prune!(deliv_mod, older_than, tenant, batch_size, opts)
       when is_integer(batch_size) and batch_size > 0 and batch_size <= 5_000 do
    prune_batch(deliv_mod, older_than, tenant, batch_size, 0, opts)
  end

  defp prune!(_deliv_mod, _older_than, _tenant, _batch_size, _opts),
    do: {:error, :invalid_batch_size}

  defp prune_batch(deliv_mod, older_than, tenant, batch_size, total, opts) do
    require Ash.Query

    result = prune_delivery_batch(deliv_mod, older_than, tenant, batch_size, opts[:attempts])

    case result do
      {:ok, rows} when length(rows) < batch_size ->
        {:ok, total + length(rows)}

      {:ok, rows} ->
        prune_batch(deliv_mod, older_than, tenant, batch_size, total + length(rows), opts)

      {:error, _} = error ->
        error
    end
  end

  defp prune_delivery_batch(deliv_mod, older_than, tenant, batch_size, attempts_mod) do
    operation = fn ->
      result =
        deliv_mod
        |> Ash.Query.filter(status in [:succeeded, :dead_letter] and inserted_at < ^older_than)
        |> Ash.Query.limit(batch_size)
        |> Ash.bulk_destroy(:prune, %{},
          authorize?: false,
          return_records?: true,
          return_errors?: true,
          strategy: [:atomic],
          tenant: tenant
        )

      case result do
        %Ash.BulkResult{status: :success, records: rows} ->
          with :ok <- prune_attempt_history(attempts_mod, rows, tenant), do: {:ok, rows}

        %Ash.BulkResult{} = failure ->
          bulk_failure(failure)
      end
    end

    if attempts_mod do
      resources = [deliv_mod, attempts_mod]

      if Enum.all?(resources, &Ash.DataLayer.can?(:transact, &1)) do
        case Ash.transact(resources, operation, tenant: tenant) do
          {:ok, {:ok, rows}} -> {:ok, rows}
          {:error, _} = error -> error
        end
      else
        {:error, :transactions_not_supported}
      end
    else
      operation.()
    end
  end

  defp prune_attempt_history(nil, _rows, _tenant), do: :ok
  defp prune_attempt_history(_attempts_mod, [], _tenant), do: :ok

  defp prune_attempt_history(attempts_mod, rows, tenant) do
    keys = Enum.map(rows, &PrimaryKey.encode(&1))

    result =
      attempts_mod
      |> Ash.Query.filter(delivery_pk in ^keys)
      |> Ash.bulk_destroy(:prune, %{},
        authorize?: false,
        return_records?: false,
        return_errors?: true,
        strategy: [:atomic],
        tenant: tenant
      )

    case result do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{} = failure -> bulk_failure(failure)
    end
  end

  @doc """
  Drives one delivery from the worker's JSON-safe args. Current jobs carry
  `delivery_pk`, `delivery_resource`, `endpoint_resource`, `endpoint_id`,
  `event_uuid`, `dispatch_source`, `dispatch_route`, and an optional `tenant`.
  String keys are Oban's JSON round-trip shape; atom keys are tolerated.
  Legacy jobs carrying only `endpoint_id` and `event_uuid` remain readable.
  The tenant arg is the enqueue seam's serialized row tenant
  (the worker reads it off the multitenancy attribute at enqueue time);
  `run/2` re-parses it through the resource's tenancy pipeline by passing
  it as the tenant on every data call; a worker restart or replica
  handoff recovers full tenant context from args alone.

  Returns `:ok` (terminal or attempted-to-terminal), `{:snooze, seconds}`
  (retry later), or `{:error, term}` for a broken trigger (row missing →
  `:ok`; the durable row is the record; a missing row is a completed or
  reaped delivery, not a failure). A tenant-less trigger against
  multitenant resources is `{:error, :tenant_required}` before any data
  access. A trigger whose resource, source, route, or complete primary key does
  not match the fetched row fails explicitly.

  Required config keys are `:deliveries`, `:endpoints`, and
  `:secret_resolver`. `:attempt_timeout` defaults to 25,000 ms and
  `:finalization_allowance` to 5,000 ms. Retry defaults are 10 attempts,
  2-second base backoff, 3,600-second maximum backoff, and an 86,400-second
  `Retry-After` cap. Omitted or `nil` retry options use these defaults.
  `:http`, `:http_opts`, `:tenant_aware_secrets`,
  `:snippet_capture`, `:snippet_redactor`, `:destination_policy`
  (`{module, function}` or a 2-arity fn; `AshHooks.DestinationPolicy`), and
  `:now` customize the documented seams.

  Optional `:retryable_statuses` replaces the retry set with a list of HTTP
  status integers/ranges. `nil` preserves the default; `[]` retries no ordinary
  HTTP failures. 2xx success, redirect refusal, and 410 disablement remain fixed.
  Invalid sets return `{:error, :invalid_retryable_statuses}` before any claim.

  `:delivery_headers` is a map/list, `{module, function}`, or three-argument
  function `(delivery, endpoint, tenant) -> headers`. Package signature,
  content-type, and framing headers are reserved case-insensitively. Invalid
  headers or callback failure retry without sending.

  `:certificate_pin` is a pin or `(endpoint, tenant)` resolver (`{module,
  function}` or function). It overrides `http_opts[:certificate_pin]`, including
  a `nil` result. Pins require `AshHooks.Http.Bounded` and HTTPS; resolver/config
  failures and mismatches are non-retryable. See `AshHooks.Http.Bounded` for pin
  formats. No configuration is cached in process-local state.

  Set `:max_attempts` here to configure the delivery row's ceiling. The worker
  macro calls this option `:delivery_max_attempts`; its own `:max_attempts`
  configures Oban's job attempts. Other retry option names are the same.
  """
  @spec run(map(), keyword()) :: :ok | {:snooze, pos_integer()} | {:error, term()}
  def run(args, config) when is_map(args) do
    with :ok <- validate_retryable_statuses(config[:retryable_statuses]),
         do: run_configured(args, config)
  end

  @doc false
  def validate_retryable_statuses(nil), do: :ok

  def validate_retryable_statuses(statuses) when is_list(statuses) do
    if Enum.all?(statuses, &valid_retry_status?/1),
      do: :ok,
      else: {:error, :invalid_retryable_statuses}
  end

  def validate_retryable_statuses(_), do: {:error, :invalid_retryable_statuses}

  defp valid_retry_status?(code) when is_integer(code), do: code in 100..599

  defp valid_retry_status?(%Range{first: first, last: last}),
    do: first in 100..599 and last in 100..599

  defp valid_retry_status?(_), do: false

  defp run_configured(args, config) do
    config =
      Enum.reduce(
        [
          max_attempts: 10,
          base_backoff_seconds: 2,
          max_backoff_seconds: 3600,
          retry_after_cap_seconds: 86_400
        ],
        config,
        fn {key, default}, normalized ->
          Keyword.update(normalized, key, default, fn
            nil -> default
            value -> value
          end)
        end
      )

    timeout = config[:attempt_timeout] || 25_000
    allowance = config[:finalization_allowance] || 5_000
    owner = self()
    started = System.monotonic_time(:millisecond)
    attempt_deadline = started + timeout
    final_deadline = attempt_deadline + allowance

    config =
      config
      |> Keyword.put(:claim_owner, owner)

    {pid, monitor} =
      spawn_monitor(fn ->
        config =
          Keyword.put(
            config,
            :driver_deadline,
            DateTime.add(now(config), timeout + allowance, :millisecond)
          )

        send(owner, {:delivery_result, self(), execute(args, config)})
      end)

    await_driver(pid, monitor, attempt_deadline, final_deadline, nil, config)
  end

  defp execute(args, config) do
    config = resolve_http_opts(config)

    with {:ok, tenant} <-
           Tenancy.resolve(
             Enum.reject([config[:deliveries], config[:endpoints], config[:attempts]], &is_nil/1),
             value(args, :tenant)
           ),
         {:ok, row} <- fetch_row_result(config[:deliveries], args, tenant),
         {:ok, row} <- validate_or_bind_execution(row, args, config, tenant) do
      if row, do: drive_row(row, config, tenant), else: :ok
    end
  end

  defp resolve_http_opts(config) do
    case config[:http_opts] do
      {module, function, args}
      when is_atom(module) and is_atom(function) and is_list(args) ->
        Keyword.put(config, :http_opts, apply(module, function, args))

      _literal_or_nil ->
        config
    end
  end

  defp await_driver(pid, monitor, deadline, final_deadline, claimed, config) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:delivery_claimed, ^pid, row, tenant} ->
        await_driver(pid, monitor, deadline, final_deadline, {row, tenant}, config)

      {:delivery_result, ^pid, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        case claimed do
          nil ->
            {:error, {:driver_crash, AshHooks.Telemetry.classify_token(reason)}}

          {row, tenant} ->
            finalize_driver_failure(row, "driver_crash", config, tenant, final_deadline)
        end
    after
      remaining ->
        Process.exit(pid, :kill)

        case await_termination(pid, monitor, final_deadline) do
          :ok ->
            case claimed do
              nil ->
                {:error, :attempt_timeout}

              {row, tenant} ->
                finalize_driver_failure(row, "attempt_timeout", config, tenant, final_deadline)
            end

          :timeout ->
            {:error, :finalization_timeout}
        end
    end
  end

  defp await_termination(pid, monitor, deadline) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> :timeout
    end
  end

  defp finalize_driver_failure(row, reason, config, tenant, deadline) do
    owner = self()
    result_ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result = retry(row, reason, config, tenant, nil)
        send(owner, {:delivery_finalization, result_ref, self(), result})
      end)

    receive do
      {:delivery_finalization, ^result_ref, ^pid, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, crash_reason} ->
        {:error, {:finalization_crash, AshHooks.Telemetry.classify_token(crash_reason)}}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        {:error, :finalization_timeout}
    end
  end

  defp drive_row(row, config, tenant) do
    case row.status do
      status when status in [:succeeded, :dead_letter] -> :ok
      :disable_pending -> complete_disable(row, config, tenant)
      :failed_retryable -> maybe_wait(row, config, tenant)
      :sending -> maybe_reclaim_sending(row, config, tenant)
      _attemptable -> attempt(row, config, tenant)
    end
  end

  defp maybe_reclaim_sending(row, config, tenant) do
    now = now(config)

    if row.send_lease_expires_at && DateTime.compare(row.send_lease_expires_at, now) == :gt do
      {:snooze, clamp_snooze(DateTime.diff(row.send_lease_expires_at, now, :second))}
    else
      attempt(row, config, tenant)
    end
  end

  # :missing is a COMPLETED delivery (the durable row is the record), not a
  # failure — normalized to :ok so the with-chain stays flat
  defp fetch_row_result(deliv_mod, args, tenant) do
    case fetch_row(deliv_mod, args, tenant) do
      {:ok, row} -> {:ok, row}
      :missing -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  # the tenant rides args in its JSON round-trip shape (string/integer —
  # never stringified: Ash.ToTenant accepts those verbatim, and the
  # resource's parse_attribute is applied by Ash itself)
  defp value(args, name) do
    Map.get(args, Atom.to_string(name)) || Map.get(args, name)
  end

  defp fetch_row(deliv_mod, args, tenant) do
    case delivery_query(deliv_mod, args) do
      :missing ->
        :missing

      {:ok, query} ->
        query
        |> Ash.read_one(authorize?: false, tenant: tenant)
        |> case do
          {:ok, nil} -> :missing
          {:ok, row} -> {:ok, row}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delivery_query(deliv_mod, args) do
    case value(args, :delivery_pk) do
      encoded when is_map(encoded) -> primary_key_delivery_query(deliv_mod, encoded)
      _legacy -> legacy_delivery_query(deliv_mod, args)
    end
  end

  defp primary_key_delivery_query(deliv_mod, encoded) do
    case PrimaryKey.decode(deliv_mod, encoded) do
      {:ok, key} -> {:ok, Ash.Query.do_filter(deliv_mod, key)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp legacy_delivery_query(deliv_mod, args) do
    case {value(args, :endpoint_id), value(args, :event_uuid)} do
      {endpoint_id, event_uuid} when is_binary(endpoint_id) and is_binary(event_uuid) ->
        {:ok,
         Ash.Query.filter(deliv_mod, endpoint_id == ^endpoint_id and event_uuid == ^event_uuid)}

      {nil, nil} ->
        :missing

      _invalid ->
        {:error, :invalid_delivery_identity}
    end
  end

  defp validate_or_bind_execution(nil, _args, _config, _tenant), do: {:ok, nil}

  defp validate_or_bind_execution(row, args, config, tenant) do
    with :ok <- validate_resource_arg(args, :delivery_resource, config[:deliveries]),
         :ok <- validate_resource_arg(args, :endpoint_resource, config[:endpoints]),
         :ok <- validate_expected(value(args, :dispatch_source), row.dispatch_source, :source),
         :ok <- validate_expected(value(args, :dispatch_route), row.dispatch_route, :route),
         :ok <- validate_config_route(row, config),
         {:ok, row} <- bind_direct_source(row, config, tenant),
         true <- OutboundBinding.endpoint_resource?(row.dispatch_source, config[:endpoints]) do
      {:ok, row}
    else
      false -> {:error, :endpoint_resource_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp validate_resource_arg(args, key, expected) do
    expected = Atom.to_string(expected)

    case value(args, key) do
      nil -> :ok
      ^expected -> :ok
      _ -> {:error, :worker_resource_mismatch}
    end
  end

  defp validate_expected(nil, _stored, _kind), do: :ok
  defp validate_expected(value, value, _kind), do: :ok
  defp validate_expected(_value, _stored, :source), do: {:error, :dispatch_source_conflict}
  defp validate_expected(_value, _stored, :route), do: {:error, :dispatch_route_conflict}

  defp validate_config_route(row, config) do
    case config[:dispatch_route] do
      nil -> :ok
      route when route == row.dispatch_route -> :ok
      _ -> {:error, :dispatch_route_conflict}
    end
  end

  defp bind_direct_source(%{dispatch_source: source} = row, config, tenant)
       when source == "v1:direct:unbound" do
    bound = OutboundBinding.direct_source(config[:deliveries], config[:endpoints])

    result =
      config[:deliveries]
      |> Ash.Query.do_filter(PrimaryKey.filter(row))
      |> Ash.Query.filter(dispatch_source == ^OutboundBinding.direct_unbound_source())
      |> Ash.bulk_update(:bind_dispatch_source, %{dispatch_source: bound},
        authorize?: false,
        return_records?: true,
        return_errors?: true,
        strategy: [:atomic],
        tenant: tenant
      )

    case result do
      %Ash.BulkResult{status: :success, records: [updated]} -> {:ok, updated}
      %Ash.BulkResult{status: :success, records: []} -> {:error, :dispatch_source_conflict}
      %Ash.BulkResult{} = result -> bulk_failure(result)
    end
  end

  defp bind_direct_source(row, _config, _tenant), do: {:ok, row}

  @doc """
  Re-arms matching terminal delivery rows through `resend/2`.

  Filters: `:endpoint_id`, `:event_type`, required `:status` list, and
  `:from` / `:to` DateTime bounds on `inserted_at`. The resource needs that
  timestamp attribute.

  Options: required `:endpoints` and `:requested_by`, plus `:enqueue`,
  `:tenant`, `:now`, `:dry_run`, `:limit` (default 100, maximum 1,000), and
  `:per_second` (default 50). Dry run counts the selected batch after applying
  `:limit`, returning `{:ok, %{count: n}}` without changing rows.

  A mutating call sleeps between second-sized batches to limit re-arming.
  Gone or disabled endpoints are skipped: `{:ok, %{resent: n, skipped: n}}`.
  Repeated calls can select skipped rows again; this API returns no pagination
  cursor.
  """
  @spec replay(module(), keyword()) ::
          {:ok, %{resent: non_neg_integer(), skipped: non_neg_integer()}}
          | {:ok, %{count: non_neg_integer()}}
          | {:error, term()}
  def replay(deliv_mod, opts \\ []) do
    with {:ok, requested_by} <- validate_requested_by(opts[:requested_by]),
         :ok <- require_resend_tracking(deliv_mod),
         {:ok, endpoints} <- require_endpoint_module(opts[:endpoints]),
         {:ok, tenant} <- Tenancy.resolve([deliv_mod, endpoints], opts[:tenant]),
         {:ok, candidates} <- replay_candidates(deliv_mod, opts, tenant) do
      if opts[:dry_run] do
        {:ok, %{count: length(candidates)}}
      else
        replay_rows(candidates, requested_by, opts, endpoints, tenant)
      end
    end
  end

  defp replay_candidates(deliv_mod, opts, tenant) do
    statuses = opts[:status]
    limit = replay_limit(opts[:limit])

    if is_nil(limit) do
      {:error, :invalid_limit}
    else
      replay_candidates_query(deliv_mod, statuses, limit, opts, tenant)
    end
  end

  defp replay_candidates_query(deliv_mod, statuses, limit, opts, tenant) do
    if is_list(statuses) and statuses != [] do
      if ResourceInfo.attribute(deliv_mod, :inserted_at) do
        query =
          deliv_mod
          |> Ash.Query.filter(status in ^statuses)
          |> replay_optional_filters(opts)
          |> Ash.Query.sort(inserted_at: :asc)
          |> Ash.Query.limit(limit)

        Ash.read(query, authorize?: false, tenant: tenant)
      else
        {:error,
         UnknownError.exception(
           error:
             inspect(deliv_mod) <>
               " has no :inserted_at — add `timestamps()` to its attributes " <>
               "(and the columns to its migration) to use replay"
         )}
      end
    else
      {:error, :status_filter_required}
    end
  end

  defp replay_optional_filters(query, opts) do
    query
    |> replay_eq(:endpoint_id, opts[:endpoint_id])
    |> replay_eq(:event_type, opts[:event_type])
    |> replay_time_range(opts[:from], opts[:to])
  end

  defp replay_eq(query, _field, nil), do: query

  defp replay_eq(query, field, value) do
    require Ash.Expr
    ref = Ash.Expr.ref(field)
    expression = Ash.Expr.expr(^ref == ^value)
    Ash.Query.filter(query, ^expression)
  end

  defp replay_time_range(query, nil, nil), do: query

  defp replay_time_range(query, from, to) do
    require Ash.Expr
    time = Ash.Expr.ref(:inserted_at)

    lower = if from, do: Ash.Expr.expr(^time >= ^from)
    upper = if to, do: Ash.Expr.expr(^time <= ^to)

    expression =
      case {lower, upper} do
        {one, nil} -> one
        {nil, one} -> one
        {lower, upper} -> Ash.Expr.expr(^lower and ^upper)
      end

    Ash.Query.filter(query, ^expression)
  end

  defp replay_limit(nil), do: 100

  defp replay_limit(n) when is_integer(n) and n in 1..1_000, do: n

  defp replay_limit(_invalid), do: nil

  defp replay_rows([], _requested_by, _opts, _endpoints, _tenant),
    do: {:ok, %{resent: 0, skipped: 0}}

  defp replay_rows(candidates, requested_by, opts, endpoints, tenant) do
    per_second = opts[:per_second] || 50

    candidates
    |> Enum.chunk_every(per_second)
    |> Enum.with_index()
    |> Enum.reduce({0, 0}, fn {batch, index}, counts ->
      # the rate limit: one second between second-sized batches
      if index > 0, do: Process.sleep(1_000)
      merge_counts(counts, replay_batch(batch, requested_by, opts, endpoints, tenant))
    end)
    |> then(fn {resent, skipped} -> {:ok, %{resent: resent, skipped: skipped}} end)
  end

  defp merge_counts({r1, s1}, {r2, s2}), do: {r1 + r2, s1 + s2}

  # a row is skipped when its endpoint is not live OR its re-arm lost a
  # race (a concurrent writer moved the row) — both are counted, never
  # fatal to the sweep
  defp replay_batch(batch, requested_by, opts, endpoints, tenant) do
    Enum.reduce(batch, {0, 0}, fn row, counts ->
      cond do
        live_endpoint(endpoints, row.endpoint_id, tenant) != :ok ->
          merge_counts(counts, {0, 1})

        match?({:ok, _}, rearm_row(row, requested_by, opts, tenant)) ->
          merge_counts(counts, {1, 0})

        true ->
          merge_counts(counts, {0, 1})
      end
    end)
  end

  @doc """
  Sends one signed synthetic TEST event of a chosen type to ONE endpoint,
  OUTSIDE subscriptions; no subscription row is consulted or needed, and
  the delivery lands in your ledger like any other (the delivery log is
  the record).

  The event gets a fresh `msg_` id (every test send is a new event; no
  dedup suppression), the chosen type verbatim, and the `:signing_mode`
  option, defaulting to `:standard`. The default payload marks itself:

      {"test": true, "type": "invoice.paid", "timestamp": "..."}

  A caller-supplied `:payload` (exact bytes) is used VERBATIM; wrap your
  own test marker into it; the package never rewrites caller bytes.

  No subscription signing mode is inferred. `:signing_mode` defaults to `:standard`.

  Options: `:type` (required, atom or nonempty binary), `:payload`, `:signing_mode`,
  `:deliveries` (the delivery resource, required), `:secret_resolver`
  (required, the driver contract), `:max_attempts` (default 1; a test
  send reports one attempt's outcome; raise it for a retried test),
  plus the driver passthroughs (`:http`, `:http_opts`,
  `:destination_policy`, `:ssrf_check`, `:tenant_aware_secrets`,
  `:attempts`, `:tenant`, `:now`). The endpoint must be live
  (`{:error, :endpoint_not_live}` otherwise); the tenancy pre-flight
  applies across the delivery and endpoint resources.

  Emits `[:ash_hooks, :delivery, :test]` (`%{endpoint_id, type}`) beside
  the normal attempt/result lifecycle, then drives the row synchronously:
  `{:ok, %{status: final_status, delivery: row}}` (the row is the record)
  or `{:error, reason}` for pre-send failures.
  """
  @spec test_send(struct(), keyword()) ::
          {:ok, %{status: atom(), delivery: struct()}} | {:error, term()}
  def test_send(endpoint, opts \\ []) do
    endpoints = endpoint.__struct__

    with {:ok, type} <- validate_test_type(opts[:type]),
         {:ok, deliveries} <- require_deliveries_module(opts[:deliveries]),
         {:ok, tenant} <-
           Tenancy.resolve(
             Enum.reject([deliveries, endpoints, opts[:attempts]], &is_nil/1),
             opts[:tenant]
           ),
         :ok <- live_endpoint(endpoints, PrimaryKey.scalar!(endpoint), tenant),
         {:ok, event} <-
           AshHooks.Event.new(
             type: type,
             payload: test_payload(type, opts),
             id: Signing.generate_msg_id()
           ),
         {:ok, row} <- create_test_row(deliveries, endpoint, event, opts, tenant) do
      :telemetry.execute(
        [:ash_hooks, :delivery, :test],
        %{},
        %{endpoint_id: row.endpoint_id, type: type}
      )

      drive_test_row(row, opts, endpoints, tenant)
    end
  end

  defp validate_test_type(type) when is_atom(type) and not is_nil(type),
    do: validate_test_type(Atom.to_string(type))

  defp validate_test_type(type) when is_binary(type) and type != "" and byte_size(type) <= 255,
    do: {:ok, type}

  defp validate_test_type(_invalid), do: {:error, :type_required}

  defp test_payload(_type, opts) do
    case opts[:payload] do
      payload when is_binary(payload) and payload != "" ->
        payload

      _synthetic ->
        Jason.encode!(%{
          "test" => true,
          "type" => opts[:type] |> to_string(),
          "timestamp" => DateTime.to_iso8601(synthetic_now(opts))
        })
    end
  end

  # a fresh event id per send keeps the {endpoint, event} identity unique —
  # test sends never collide with (or suppress) each other
  # a broken application clock must not break payload synthesis — the
  # marker's timestamp falls back to the wall clock (the driver still
  # enforces the clock contract where it governs durable state)
  defp synthetic_now(opts) do
    now(opts)
  rescue
    _reason -> DateTime.utc_now()
  end

  defp create_test_row(deliveries, endpoint, event, opts, tenant) do
    input =
      %{test: true}
      |> Map.merge(%{
        event_uuid: event.id,
        event_type: event.type,
        endpoint_id: PrimaryKey.scalar!(endpoint),
        subscription_id: nil,
        signing_mode: opts[:signing_mode] || :standard
      })
      |> Map.put(AshHooks.Info.payload_attribute(deliveries), event.payload)
      # the flag rides only resources that carry the column
      |> Map.drop(if ResourceInfo.attribute(deliveries, :test), do: [], else: [:test])

    Ash.create(deliveries, input, action: :dispatch, authorize?: false, tenant: tenant)
  end

  defp drive_test_row(row, opts, endpoints, tenant) do
    config =
      opts
      |> Keyword.put(:deliveries, row.__struct__)
      |> Keyword.put(:endpoints, endpoints)
      |> Keyword.put_new(:max_attempts, 1)

    args = %{
      "delivery_pk" => PrimaryKey.encode(row),
      "delivery_resource" => Atom.to_string(row.__struct__),
      "endpoint_resource" => Atom.to_string(endpoints),
      "endpoint_id" => row.endpoint_id,
      "event_uuid" => row.event_uuid,
      "dispatch_source" => row.dispatch_source,
      "dispatch_route" => row.dispatch_route
    }

    args = if tenant, do: Map.put(args, "tenant", tenant), else: args

    case run(args, config) do
      :ok -> final_test_row(row, tenant)
      {:snooze, _delay} -> final_test_row(row, tenant)
      {:error, reason} -> {:error, reason}
    end
  end

  defp final_test_row(row, tenant) do
    final = Ash.get!(row.__struct__, row.id, authorize?: false, tenant: tenant)
    {:ok, %{status: final.status, delivery: final}}
  end

  defp require_deliveries_module(module) when is_atom(module) and not is_nil(module),
    do: {:ok, module}

  defp require_deliveries_module(_invalid),
    do: {:error, UnknownError.exception(error: "test_send requires the :deliveries resource")}

  # ────────────────────────── gating ──────────────────────────

  defp maybe_wait(row, config, tenant) do
    now = now(config)

    if row.next_attempt_at && DateTime.compare(row.next_attempt_at, now) == :gt do
      {:snooze, clamp_snooze(DateTime.diff(row.next_attempt_at, now, :second))}
    else
      attempt(row, config, tenant)
    end
  end

  defp attempt(row, config, tenant) do
    if series_attempts(row) >= config[:max_attempts] do
      terminalize_exhausted(row, config, tenant)
    else
      claim_then_attempt(row, config, tenant)
    end
  end

  # The row's attempt series: monotonic lifetime attempts minus the ladder
  # baseline a resend set. Without resend tracking (no column) the series
  # IS the lifetime count — the pre-2.2 gate unchanged.
  defp series_attempts(row), do: row.attempts - Map.get(row, :resend_baseline, 0)

  @doc """
  Re-arms one TERMINAL delivery row (`:succeeded` / `:dead_letter`) for a
  resend: the row keeps its id and `event_uuid` (a Standard Webhooks
  receiver deduplicates the repeat POST by webhook-id), its lifetime
  `attempts` counter keeps climbing (attempt-history rows stay unique),
  and a fresh retry ladder starts at the current count
  (`resend_baseline`).

  Options:

    * `:endpoints` (required); the endpoint resource, for the live check.
    * `:requested_by` (required, nonempty binary ≤ 255); recorded on the
      row (`last_resend_by`/`last_resend_at`, `resend_count` bumps).
    * `:enqueue`; the same enqueue seam dispatch uses (`{module, function}`
      or a 2-arity fn); `nil` re-arms the row and leaves driving to your
      worker/recovery.
    * `:tenant`; the tenancy pre-flight applies.
    * `:now`; the application clock for `last_resend_at`.

  Only live endpoints resend: gone or disabled endpoints return
  `{:error, :endpoint_not_live}` before any write; a non-terminal row is
  `{:error, :not_resendable}`; a resource without `resend_tracking :on`
  fails with a named error (the columns are its migration). Every resend
  emits `[:ash_hooks, :delivery, :resend]` carrying the ids and
  `requested_by`. Returns `{:ok, %{status: :resent, delivery: row}}`.
  """
  @spec resend(struct(), keyword()) ::
          {:ok, %{status: :resent, delivery: struct()}} | {:error, term()}
  def resend(row, opts \\ []) do
    resource = row.__struct__

    with {:ok, requested_by} <- validate_requested_by(opts[:requested_by]),
         :ok <- require_resend_tracking(resource),
         {:ok, endpoints} <- require_endpoint_module(opts[:endpoints]),
         {:ok, tenant} <- Tenancy.resolve([resource, endpoints], opts[:tenant]),
         :ok <- resendable(row),
         :ok <- live_endpoint(endpoints, row.endpoint_id, tenant) do
      rearm_row(row, requested_by, opts, tenant)
    end
  end

  defp validate_requested_by(requested_by)
       when is_binary(requested_by) and requested_by != "" and byte_size(requested_by) <= 255,
       do: {:ok, requested_by}

  defp validate_requested_by(_invalid), do: {:error, :requested_by_required}

  defp require_resend_tracking(resource) do
    if ResourceInfo.action(resource, :resend) do
      :ok
    else
      {:error,
       UnknownError.exception(
         error:
           inspect(resource) <>
             " does not carry the resend-tracking columns (resend_tracking :off) — " <>
             "declare `resend_tracking :on` under `outbound_delivery` and migrate the " <>
             "four columns to use resend/replay"
       )}
    end
  end

  defp require_endpoint_module(nil),
    do: {:error, UnknownError.exception(error: "resend/replay require the :endpoints resource")}

  defp require_endpoint_module(module) when is_atom(module), do: {:ok, module}

  defp resendable(%{status: status}) when status in [:succeeded, :dead_letter], do: :ok
  defp resendable(_other_status), do: {:error, :not_resendable}

  defp live_endpoint(endpoints, endpoint_id, tenant) do
    case Ash.get(endpoints, endpoint_id, authorize?: false, tenant: tenant) do
      {:ok, endpoint} ->
        if AshHooks.Endpoint.enabled?(endpoint), do: :ok, else: {:error, :endpoint_not_live}

      {:error, _reason} ->
        {:error, :endpoint_not_live}
    end
  end

  defp rearm_row(row, requested_by, opts, tenant) do
    requested_at = now(opts)

    result =
      row.__struct__
      |> Ash.Query.do_filter(PrimaryKey.filter(row))
      |> Ash.Query.filter(
        dispatch_source == ^row.dispatch_source and status in [:succeeded, :dead_letter]
      )
      |> Ash.bulk_update(
        :resend,
        %{
          resend_baseline: row.attempts,
          requested_by: requested_by,
          requested_at: requested_at
        },
        authorize?: false,
        return_records?: true,
        return_errors?: true,
        strategy: [:atomic],
        tenant: tenant
      )

    case result do
      %Ash.BulkResult{status: :success, records: [updated]} ->
        :telemetry.execute(
          [:ash_hooks, :delivery, :resend],
          %{},
          %{
            endpoint_id: updated.endpoint_id,
            event_uuid: updated.event_uuid,
            requested_by: requested_by
          }
        )

        case enqueue_seam_result(opts[:enqueue], updated) do
          :ok ->
            {:ok, %{status: :resent, delivery: updated}}

          {:error, reason} ->
            {:ok, %{status: :resent, delivery: updated, enqueue: {:error, reason}}}
        end

      %Ash.BulkResult{status: :success, records: []} ->
        {:error, :not_resendable}

      %Ash.BulkResult{} = result ->
        bulk_failure(result)
    end
  end

  # the enqueue seam, contained like the dispatcher's (a raise/exit/throw
  # is an enqueue failure, never a resend failure — the re-arm is durable)
  defp enqueue_seam_result(nil, _row), do: :ok

  defp enqueue_seam_result({m, f}, row) when is_atom(m) and is_atom(f),
    do: enqueue_seam_result(&apply(m, f, [&1, &2]), row)

  defp enqueue_seam_result(enqueuer, row) when is_function(enqueuer, 2) do
    case enqueuer.(row, nil) do
      :ok -> :ok
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_enqueue_result}
    end
  rescue
    reason -> {:error, {:raised, reason}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp claim_then_attempt(row, config, tenant) do
    case mark_sending(row, config, tenant) do
      {:ok, sending} ->
        if owner = config[:claim_owner],
          do: send(owner, {:delivery_claimed, self(), sending, tenant})

        attempt_claimed(sending, config, tenant)

      :contended ->
        {:snooze, 1}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp attempt_claimed(row, config, tenant) do
    case Ash.get(config[:endpoints], row.endpoint_id, authorize?: false, tenant: tenant) do
      # the ONE enabled-check (H4): the injected status attribute or the
      # consumer-mapped switch — exactly one attribute dead-letters
      {:ok, endpoint} ->
        if AshHooks.Endpoint.enabled?(endpoint) do
          attempt_enabled(row, endpoint, config, tenant)
        else
          dead_letter(row, "endpoint_disabled", config, tenant)
        end

      # only a GONE endpoint row is terminal — a transient read error must
      # retry, never permanently dead-letter
      {:error, %Ash.Error.Invalid{errors: reasons}} = error ->
        if Enum.all?(reasons, &is_struct(&1, Ash.Error.Query.NotFound)) do
          dead_letter(row, "endpoint_gone", config, tenant)
        else
          {:error, error}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp attempt_enabled(row, endpoint, config, tenant) do
    transport = resolve_transport(endpoint, config, tenant)

    if transport do
      # a routed transport OWNS destination semantics: the packaged
      # send-time gate (and the policy seam) describe HTTP destinations
      send(row, endpoint, config, tenant, transport)
    else
      attempt_gated(row, endpoint, config, tenant)
    end
  end

  defp attempt_gated(row, endpoint, config, tenant) do
    # the public destination-policy seam first: a consumer policy decides
    # allow/deny/default per URL ahead of the packaged gate, so an app can
    # carry its own allow and deny rules without forking the default
    # check. A configured policy TAKES PRECEDENCE over the boolean
    # :ssrf_check seam.
    case config[:destination_policy] do
      nil ->
        attempt_under_default_policy(row, endpoint, config, tenant)

      policy ->
        case run_destination_policy(policy, endpoint, tenant) do
          :allow ->
            send(row, endpoint, config, tenant)

          :deny ->
            dead_letter(row, "destination_denied", config, tenant)

          :default ->
            attempt_under_default_policy(row, endpoint, config, tenant)

          {:error, :policy_failed} ->
            retry(row, "destination_policy_failed", config, tenant, nil)
        end
    end
  end

  # the policy callback runs inside the driver's containment: a crash or a
  # term outside the decision vocabulary is a RETRYABLE failure (the row
  # climbs the ladder while the app fixes its policy — a policy defect
  # must not dead-letter deliveries)
  defp run_destination_policy({m, f}, endpoint, tenant) when is_atom(m) and is_atom(f),
    do:
      safe_destination_policy(fn ->
        apply(m, f, [endpoint.url, policy_context(endpoint, tenant)])
      end)

  defp run_destination_policy(policy, endpoint, tenant) when is_function(policy, 2),
    do: safe_destination_policy(fn -> policy.(endpoint.url, policy_context(endpoint, tenant)) end)

  defp run_destination_policy(_invalid_shape, _endpoint, _tenant),
    do: {:error, :policy_failed}

  defp safe_destination_policy(fun) do
    classify_destination_decision(fun.())
  rescue
    _reason -> {:error, :policy_failed}
  catch
    :exit, _reason -> {:error, :policy_failed}
    :throw, _value -> {:error, :policy_failed}
  end

  defp policy_context(endpoint, tenant),
    do: %{endpoint_id: PrimaryKey.scalar!(endpoint), tenant: tenant}

  defp classify_destination_decision(decision) when decision in [:allow, :deny, :default],
    do: decision

  defp classify_destination_decision(_invalid), do: {:error, :policy_failed}

  defp attempt_under_default_policy(row, endpoint, config, tenant) do
    # send-time re-check: full DNS re-resolution by default (ADR-0005);
    # the seam is injectable so deterministic tests use the
    # literal-only variant. The default runs the tri-state resolver so an
    # UNRESOLVABLE host retries under its honest label — a resolver
    # outage is transport, not a verdict on the destination — and only a
    # validated-unsafe answer dead-letters. (The boolean `safe_url?/1`
    # folded both into one `false`, dead-lettering DNS outages as
    # "unsafe_destination" at attempts == 1.)
    case config[:ssrf_check] do
      nil ->
        case AshHooks.Ssrf.resolve_public(endpoint.url) do
          {:ok, _validated} ->
            send(row, endpoint, config, tenant)

          {:error, :unsafe} ->
            dead_letter(row, "unsafe_destination", config, tenant)

          # nxdomain (authoritative negative) vs resolve_timeout (outage,
          # congestion, mixed evidence) — both retry; the row ceiling
          # terminalizes a dead domain carrying the honest label
          {:error, dns_error} when dns_error in [:nxdomain, :resolve_timeout] ->
            retry(row, Atom.to_string(dns_error), config, tenant, nil)
        end

      check ->
        if check.(endpoint.url) do
          send(row, endpoint, config, tenant)
        else
          dead_letter(row, "unsafe_destination", config, tenant)
        end
    end
  end

  # ────────────────────────── the send ──────────────────────────

  defp send(row, endpoint, config, tenant, transport \\ nil) do
    :telemetry.execute(
      [:ash_hooks, :delivery, :attempt],
      %{},
      %{
        endpoint_id: PrimaryKey.scalar!(endpoint),
        event_uuid: row.event_uuid,
        attempts: row.attempts
      }
    )

    adapter = transport || config[:http] || AshHooks.Http.Bounded

    request = if is_function(adapter, 5), do: adapter, else: &adapter.request/5

    # adapter opts seam (test listeners' validate_destination: false; real
    # consumers' timeout overrides and a pinned :cacerts trust bundle for
    # private-CA endpoints). Consumer-trusted config like :ssrf_check: it
    # CAN disable the adapter's destination pin — the driver's send-time
    # check above is the residual guarantee, not a full replacement
    adapter_opts = config[:http_opts] || []

    with {:ok, adapter_opts} <- endpoint_http_opts(adapter_opts, endpoint, config, tenant),
         :ok <- pin_adapter(adapter, adapter_opts),
         {:ok, headers} <- signing_headers(row, endpoint, config, tenant),
         {:ok, headers} <- delivery_headers(headers, row, endpoint, config, tenant) do
      stamp_key_first_used(endpoint, config, tenant)
      send_signed(request, endpoint, headers, row, adapter_opts, config, tenant)
    else
      {:error, reason}
      when reason in [:certificate_pin_resolution_failed, :certificate_pin_requires_bounded] ->
        dead_letter(row, error_string(reason), config, tenant)

      # secret-resolution and signing failures are RETRYABLE (the
      # classification table): config is fixable while the row climbs
      {:error, reason} ->
        retry(row, error_string(reason), config, tenant, nil)
    end
  end

  defp endpoint_http_opts(opts, endpoint, config, tenant) do
    case config[:certificate_pin] do
      nil ->
        {:ok, opts}

      {m, f} when is_atom(m) and is_atom(f) ->
        {:ok, Keyword.put(opts, :certificate_pin, apply(m, f, [endpoint, tenant]))}

      fun when is_function(fun, 2) ->
        {:ok, Keyword.put(opts, :certificate_pin, fun.(endpoint, tenant))}

      pin ->
        {:ok, Keyword.put(opts, :certificate_pin, pin)}
    end
  rescue
    _ -> {:error, :certificate_pin_resolution_failed}
  catch
    _, _ -> {:error, :certificate_pin_resolution_failed}
  end

  defp pin_adapter(AshHooks.Http.Bounded, _opts), do: :ok

  defp pin_adapter(_adapter, opts) do
    if is_nil(opts[:certificate_pin]), do: :ok, else: {:error, :certificate_pin_requires_bounded}
  end

  @reserved_delivery_headers ~w(host connection content-length content-type transfer-encoding
    te trailer upgrade proxy-connection keep-alive webhook-id webhook-timestamp
    webhook-signature x-webhook-signature)

  defp delivery_headers(signed, row, endpoint, config, tenant) do
    source = config[:delivery_headers]

    extra =
      case source do
        nil -> %{}
        {m, f} when is_atom(m) and is_atom(f) -> apply(m, f, [row, endpoint, tenant])
        fun when is_function(fun, 3) -> fun.(row, endpoint, tenant)
        headers -> headers
      end

    with {:ok, headers} <- Headers.validate(extra) do
      normalized = Map.new(headers, fn {name, value} -> {String.downcase(name), value} end)

      if Enum.any?(Map.keys(normalized), &reserved_delivery_header?/1) do
        {:error, :reserved_delivery_header}
      else
        {:ok, Map.merge(normalized, signed)}
      end
    end
  rescue
    _ -> {:error, :delivery_headers_failed}
  catch
    _, _ -> {:error, :delivery_headers_failed}
  end

  defp reserved_delivery_header?(name) do
    name in @reserved_delivery_headers
  end

  defp send_signed(request, endpoint, headers, row, adapter_opts, config, tenant) do
    case send_request(request, endpoint, headers, row, adapter_opts) do
      {:ok, response, started} ->
        history = attempt_history(endpoint, response, started)
        record(row, endpoint, response, config, tenant, history)

      # a pin-time SSRF refusal is a caught rebinding flip — terminal, per
      # the classification table (never burn the retry ceiling on it).
      # The request WAS attempted (the refusal came from inside it), so
      # its duration and signing key ride the history row.
      {:error, reason, started}
      when reason in [
             :unsafe_destination,
             :certificate_pin_mismatch,
             :invalid_certificate_pin,
             :certificate_pin_requires_https
           ] ->
        dead_letter(
          row,
          error_string(reason),
          config,
          tenant,
          nil,
          failed_request_history(endpoint, started)
        )

      {:error, reason, started} ->
        retry(
          row,
          error_string(reason),
          config,
          tenant,
          nil,
          nil,
          failed_request_history(endpoint, started)
        )
    end
  end

  # First-use stamps for the key lifecycle (key_lifecycle :on resources):
  # written at signing time — a key that signed was used, whatever the
  # receiver said. WHERE-gated on the stamp still being nil, so
  # steady-state sends stop writing; failures never break the send.
  defp stamp_key_first_used(endpoint, config, tenant) do
    resource = endpoint.__struct__

    if ResourceInfo.attribute(resource, :secret_first_used_at) do
      used_at = now(config)

      stamp_first_used(
        resource,
        endpoint,
        :mark_current_secret_used,
        :secret_first_used_at,
        used_at,
        tenant
      )

      if endpoint.previous_secret_ref do
        stamp_first_used(
          resource,
          endpoint,
          :mark_previous_secret_used,
          :previous_secret_first_used_at,
          used_at,
          tenant
        )
      end
    end
  end

  defp stamp_first_used(resource, endpoint, action, field, used_at, tenant) do
    if Map.get(endpoint, field) do
      :ok
    else
      require Ash.Expr
      nil_stamp = Ash.Expr.expr(is_nil(^Ash.Expr.ref(field)))

      _ =
        resource
        |> Ash.Query.do_filter(PrimaryKey.filter(endpoint))
        |> Ash.Query.filter(^nil_stamp)
        |> Ash.bulk_update(action, %{used_at: used_at},
          authorize?: false,
          return_records?: false,
          return_errors?: false,
          strategy: [:atomic],
          tenant: tenant
        )

      :ok
    end
  end

  # an adapter RAISE must not crash the job out of the row-owned policy —
  # classify it as a retryable transport failure. The start stamp rides
  # EVERY outcome: a request that failed still RAN for a measurable time,
  # and the attempt history records it (failed_request_history). The try
  # is explicit so the stamp (bound before it) stays visible in rescue.
  defp send_request(request, endpoint, headers, row, adapter_opts) do
    started = System.monotonic_time(:millisecond)

    try do
      case request.(:post, endpoint.url, headers, payload_bytes(row), adapter_opts) do
        {:ok, response} -> {:ok, response, started}
        {:error, reason} -> {:error, reason, started}
      end
    rescue
      reason -> {:error, {:adapter_crash, error_string(reason)}, started}
    end
  end

  # The failed-request history: the request was ATTEMPTED (transport
  # error, pin-time refusal, adapter crash) — its duration and the
  # signing key that signed it are facts; no response exists to
  # summarize, so the response-derived fields stay nil. Pre-send failures
  # (destination policy, DNS at the gate, secret resolution) never reach
  # here and keep latency nil — no request, no duration.
  defp failed_request_history(endpoint, started) do
    %{
      latency_ms: max(System.monotonic_time(:millisecond) - started, 0),
      signing_key_ref: endpoint.secret_ref,
      response_snippet: nil,
      response_headers: nil
    }
  end

  # ────────────────────────── the per-endpoint transport ──────────────────────────

  # The transport resolver (`transport: {m, f}` or a 2-arity fn of the
  # endpoint record and tenant) routes ONE endpoint's deliveries to the
  # app's own transport module instead of the HTTP adapter. It runs inside
  # the send path's containment: a crash or a non-module return falls back
  # to the HTTP adapter — HTTP's guarantees are the default posture.
  defp resolve_transport(endpoint, config, tenant) do
    case config[:transport] do
      nil ->
        nil

      {m, f} when is_atom(m) and is_atom(f) ->
        contained_transport(fn -> apply(m, f, [endpoint, tenant]) end)

      resolver when is_function(resolver, 2) ->
        contained_transport(fn -> resolver.(endpoint, tenant) end)

      _invalid ->
        nil
    end
  end

  defp contained_transport(fun) do
    case fun.() do
      module when is_atom(module) and not is_nil(module) -> module
      _falls_back -> nil
    end
  rescue
    _reason -> nil
  catch
    :exit, _reason -> nil
    :throw, _value -> nil
  end

  # ────────────────────────── attempt history ──────────────────────────

  # The per-attempt audit record: latency, the signing key REFERENCE (the
  # endpoint's secret store reference string — never secret material), and
  # the per-endpoint-opt-in response capture (bounded bytes, redaction
  # floor, allowlisted headers only). Without an :attempts resource
  # configured, none of this work happens.
  defp attempt_history(endpoint, response, started) do
    %{
      latency_ms: max(System.monotonic_time(:millisecond) - started, 0),
      signing_key_ref: endpoint.secret_ref,
      response_snippet: captured_attempt_snippet(endpoint, response),
      response_headers: captured_attempt_headers(endpoint, response)
    }
  end

  # capture is per-endpoint-row opt-in: the resource declared
  # `response_capture_attributes :on` AND the row set response_capture
  defp capture_enabled?(endpoint) do
    resource = endpoint.__struct__

    ResourceInfo.attribute(resource, :response_capture) != nil and
      Map.get(endpoint, :response_capture) == true
  end

  defp captured_attempt_snippet(endpoint, %{status: status} = response) do
    headers = response[:headers]
    body = response[:body]

    if capture_enabled?(endpoint) and is_binary(body) do
      body
      |> utf8_byte_cap(Map.get(endpoint, :response_capture_max_bytes, @snippet_max))
      |> redact()
      |> then(&AshHooks.BoundedText.cap(@captured_prefix <> &1, @snippet_max))
    else
      summarize(status, headers)
    end
  end

  defp captured_attempt_headers(endpoint, response) do
    headers = response[:headers]

    if capture_enabled?(endpoint) and is_list(headers) do
      allowlist = Map.get(endpoint, :response_header_allowlist, [])
      captured = allowlisted_headers(headers, allowlist)
      if captured == %{}, do: nil, else: captured
    end
  end

  defp allowlisted_headers(headers, allowlist) do
    headers
    |> Enum.flat_map(fn
      {name, value} when is_binary(name) and is_binary(value) ->
        normalized = String.downcase(name)

        if normalized in allowlist, do: [{normalized, value}], else: []

      _malformed ->
        []
    end)
    |> Map.new()
  end

  # a BYTE cap that still lands on a UTF-8 boundary — a raw binary_part
  # can split a codepoint and collapse the whole capture to [binary]
  defp utf8_byte_cap(binary, max_bytes) when byte_size(binary) <= max_bytes, do: binary

  defp utf8_byte_cap(binary, max_bytes),
    do: binary_part(binary, 0, utf8_boundary(binary, max_bytes))

  defp utf8_boundary(binary, n) do
    if String.valid?(binary_part(binary, 0, n)), do: n, else: utf8_boundary(binary, n - 1)
  end

  # One history row per attempt, written AFTER the fenced result succeeds.
  # The unique (delivery_pk, attempt) identity makes re-drives idempotent;
  # a history write failure NEVER fails the send — it surfaces as
  # [:ash_hooks, :attempt, :record_failed] telemetry and the delivery row
  # remains the contract.
  defp record_attempt(row, outcome, reason, summary, history, config, tenant) do
    case config[:attempts] do
      nil ->
        :ok

      attempts_mod ->
        write_attempt(attempts_mod, row, outcome, reason, summary, history || %{}, tenant)
    end
  end

  # the flag rides history rows: the extension ships the column, and the
  # delivery's own value (absent on test_tracking :off rows → false) is
  # the truth for the attempt
  defp write_attempt(attempts_mod, row, outcome, reason, summary, history, tenant) do
    input =
      Map.merge(%{test: Map.get(row, :test) == true}, %{
        delivery_pk: PrimaryKey.encode(row),
        endpoint_id: row.endpoint_id,
        event_uuid: row.event_uuid,
        event_type: row.event_type,
        attempt: row.attempts,
        outcome: outcome,
        reason: reason,
        response_status: summary_status(summary),
        response_snippet: attempt_snippet(summary, history),
        response_headers: history[:response_headers],
        latency_ms: history[:latency_ms],
        signing_key_ref: history[:signing_key_ref]
      })

    case Ash.create(attempts_mod, input, action: :record, authorize?: false, tenant: tenant) do
      {:ok, _attempt} ->
        :ok

      {:error, write_reason} ->
        :telemetry.execute(
          [:ash_hooks, :attempt, :record_failed],
          %{},
          %{
            endpoint_id: row.endpoint_id,
            event_uuid: row.event_uuid,
            reason: AshHooks.Telemetry.classify_token(write_reason)
          }
        )

        :ok
    end
  end

  # the attempt row prefers the history's captured snippet (per-endpoint
  # capture) over the delivery row's summary tuple
  defp attempt_snippet(_summary, %{response_snippet: captured}) when is_binary(captured),
    do: captured

  defp attempt_snippet({_status, snippet}, _history), do: snippet
  defp attempt_snippet(nil, _history), do: nil

  # the exact-bytes column's name is consumer-configurable (`payload_attribute`,
  # H1) — every runtime read goes through the row's own resource config
  defp payload_bytes(row), do: Map.get(row, AshHooks.Info.payload_attribute(row.__struct__))

  defp record(row, _endpoint, %{status: status} = response, config, tenant, history)
       when status in 200..299 do
    mark_succeeded(row, response, config, tenant, history)
  end

  # The 410 disable rides the ROW's tenant: a cross-tenant 410 (org_b's
  # worker seeing org_a's endpoint id) cannot even resolve org_a's
  # endpoint (the tenant-scoped fetch dead-letters it as endpoint_gone
  # first), and the disable write itself is tenant-filtered. The matched
  # count is checked — a zero-match "success" (the endpoint vanished
  # between fetch and write) is surfaced, never counted as a completed
  # circuit-break.
  defp record(row, endpoint, %{status: 410} = response, config, tenant, history) do
    {status, snippet} = failure_summary(response)

    case fenced_update(
           row,
           config,
           :mark_disable_pending,
           %{
             response_status: status,
             response_snippet: snippet,
             endpoint_snapshot:
               Map.put(endpoint_snapshot(endpoint), "attempt_history", history || %{})
           },
           [:sending],
           tenant
         ) do
      {:ok, [pending]} -> complete_disable(pending, config, tenant)
      {:ok, []} -> {:snooze, 1}
      {:error, reason} -> {:error, {:reconcile_failed, reason}}
    end
  end

  defp record(row, _endpoint, %{status: status} = response, config, tenant, history)
       when status in 300..399 do
    dead_letter(
      row,
      "redirect_refused_#{status}",
      config,
      tenant,
      failure_summary(response),
      history
    )
  end

  defp record(row, _endpoint, %{status: status} = response, config, tenant, history) do
    # The retryable 5xx class: Retry-After is honored here exactly as on 408/429 —
    # a 503 carrying the header names the receiver's own recovery window, and the
    # parser/clamp path is shared (absent/malformed header → nil → backoff).
    if retryable_status?(status, config[:retryable_statuses]) do
      retry(
        row,
        "http_#{status}",
        config,
        tenant,
        retry_after(response, config),
        failure_summary(response),
        history
      )
    else
      dead_letter(row, "http_#{status}", config, tenant, failure_summary(response), history)
    end
  end

  defp retryable_status?(status, nil), do: status in [408, 429] or status not in 200..499

  defp retryable_status?(status, statuses) when is_list(statuses) do
    Enum.any?(statuses, fn
      %Range{} = range -> status in range
      code -> status == code
    end)
  end

  # failed rows keep the story-1 half of the snippet policy: status + kind,
  # never body bytes (the #17 design note's D6b)
  defp failure_summary(response),
    do: {response[:status], summarize(response[:status], response[:headers])}

  # ────────────────────────── signing ──────────────────────────

  defp signing_headers(row, endpoint, config, tenant) do
    resolver = config[:secret_resolver]
    # the worker macro's :tenant_aware_secrets switch: the resolver
    # contract becomes f(ref, tenant) — explicit, no arity magic
    tenant_aware? = config[:tenant_aware_secrets] == true

    with {:ok, secret} <- resolve(endpoint.secret_ref, resolver, tenant, tenant_aware?),
         {:ok, previous} <-
           resolve_opt(endpoint.previous_secret_ref, resolver, tenant, tenant_aware?),
         {:ok, legacy} <- resolve_opt(endpoint.legacy_secret_ref, resolver, tenant, tenant_aware?),
         {:ok, legacy_previous} <-
           resolve_opt(endpoint.legacy_previous_secret_ref, resolver, tenant, tenant_aware?) do
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
          payload_bytes(row),
          opts
        )

      {:ok, Map.put(headers, "content-type", "application/json")}
    end
  rescue
    ArgumentError -> {:error, :signing_failed}
  end

  # No ref means no secret — checked FIRST so a config-shaped resolver can
  # never be misclassified as a missing reference (and vice versa).
  defp resolve(ref, _resolver, _tenant, _tenant_aware?)
       when not is_binary(ref) or ref == "",
       do: {:error, :no_secret}

  defp resolve(ref, {m, f}, tenant, tenant_aware?)
       when is_binary(ref) and is_atom(m) and is_atom(f) do
    if tenant_aware? do
      resolve_checked(fn -> apply(m, f, [ref, tenant]) end)
    else
      resolve_checked(fn -> apply(m, f, [ref]) end)
    end
  end

  defp resolve(ref, resolver, _tenant, false) when is_binary(ref) and is_function(resolver, 1),
    do: resolve_checked(fn -> resolver.(ref) end)

  defp resolve(ref, resolver, tenant, true) when is_binary(ref) and is_function(resolver, 2),
    do: resolve_checked(fn -> resolver.(ref, tenant) end)

  # a resolver whose shape does not match the declared contract (e.g. a
  # 1-arity resolver under :tenant_aware_secrets) classifies as a
  # retryable secret-resolution failure — a crash here would burn the job
  # without a classified ledger write
  defp resolve(_ref, _resolver, _tenant, _tenant_aware?),
    do: {:error, {:secret_resolution, :invalid_resolver}}

  defp resolve_checked(fun) do
    case fun.() do
      {:ok, secret} when is_binary(secret) and secret != "" -> {:ok, secret}
      {:error, reason} -> {:error, {:secret_resolution, reason}}
      _other -> {:error, {:secret_resolution, :invalid_resolver_result}}
    end
  rescue
    _bad_arity_or_undef -> {:error, {:secret_resolution, :invalid_resolver}}
  catch
    :exit, _ -> {:error, {:secret_resolution, :invalid_resolver}}
    :throw, _ -> {:error, {:secret_resolution, :invalid_resolver}}
  end

  defp resolve_opt(ref, resolver, tenant, tenant_aware?) when is_binary(ref) and ref != "",
    do: resolve(ref, resolver, tenant, tenant_aware?)

  defp resolve_opt(_nil, _resolver, _tenant, _tenant_aware?), do: {:ok, nil}

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

  # ────────────────────────── durable disable recovery ──────────────────────────

  defp complete_disable(row, config, tenant) do
    snapshot = row.endpoint_snapshot || %{}

    result =
      case PrimaryKey.decode(config[:endpoints], snapshot["endpoint_pk"] || %{}) do
        {:ok, key} ->
          with_endpoint(
            config[:endpoints],
            key,
            tenant,
            fn -> finalize_disable(row, "gone_410_endpoint_gone", config, tenant) end,
            fn endpoint ->
              apply_disable_obligation(row, endpoint, snapshot, config, tenant)
            end
          )

        {:error, reason} ->
          {:error, reason}
      end

    case result do
      :ok -> :ok
      {:error, reason} -> {:error, {:disable_failed, reason}}
    end
  end

  defp read_endpoint(resource, key, tenant) do
    resource
    |> Ash.Query.do_filter(key)
    |> Ash.read_one(authorize?: false, tenant: tenant)
    |> case do
      {:ok, nil} -> :missing
      {:ok, endpoint} -> {:ok, endpoint}
      {:error, reason} -> {:error, reason}
    end
  end

  defp with_endpoint(resource, key, tenant, missing, found) do
    case read_endpoint(resource, key, tenant) do
      :missing -> missing.()
      {:ok, endpoint} -> found.(endpoint)
      {:error, _reason} = error -> error
    end
  end

  defp apply_disable_obligation(row, endpoint, snapshot, config, tenant) do
    switch = endpoint_switch(config[:endpoints])

    cond do
      snapshot["status_attribute"] != Atom.to_string(switch) ->
        finalize_disable(row, "gone_410_endpoint_reconfigured", config, tenant)

      not endpoint_configuration_matches?(endpoint, snapshot, switch) ->
        finalize_disable(row, "gone_410_endpoint_reconfigured", config, tenant)

      not AshHooks.Endpoint.enabled?(endpoint) ->
        finalize_disable(row, "gone_410_endpoint_already_disabled", config, tenant)

      true ->
        disable_matching_endpoint(row, endpoint, snapshot, switch, config, tenant)
    end
  end

  defp endpoint_configuration_matches?(endpoint, snapshot, switch) do
    fields = [
      :url,
      :secret_ref,
      :previous_secret_ref,
      :legacy_secret_ref,
      :legacy_previous_secret_ref
    ]

    Enum.all?(fields, fn field -> Map.get(endpoint, field) == snapshot[Atom.to_string(field)] end) and
      snapshot_status_matches?(endpoint, snapshot, switch)
  end

  defp snapshot_status_matches?(endpoint, snapshot, switch) do
    definition = ResourceInfo.attribute(endpoint.__struct__, switch)

    with {:ok, cast} <-
           Ash.Type.cast_input(definition.type, snapshot["status_value"], definition.constraints),
         {:ok, value} <- Ash.Type.apply_constraints(definition.type, cast, definition.constraints) do
      Ash.Type.equal?(definition.type, Map.get(endpoint, switch), value, definition.constraints)
    else
      _ -> false
    end
  end

  defp disable_matching_endpoint(row, endpoint, snapshot, switch, config, tenant) do
    result =
      config[:endpoints]
      |> Ash.Query.do_filter(PrimaryKey.filter(endpoint))
      |> Ash.Query.filter(url == ^snapshot["url"] and secret_ref == ^snapshot["secret_ref"])
      |> optional_snapshot_filter(:previous_secret_ref, snapshot["previous_secret_ref"])
      |> optional_snapshot_filter(:legacy_secret_ref, snapshot["legacy_secret_ref"])
      |> optional_snapshot_filter(
        :legacy_previous_secret_ref,
        snapshot["legacy_previous_secret_ref"]
      )
      |> Ash.Query.do_filter(%{switch => Map.get(endpoint, switch)})
      |> Ash.bulk_update(:disable, %{},
        authorize?: false,
        return_records?: true,
        return_errors?: true,
        strategy: [:atomic],
        tenant: tenant
      )

    case result do
      %Ash.BulkResult{status: :success, records: [_]} ->
        :telemetry.execute(
          [:ash_hooks, :delivery, :disable],
          %{},
          %{endpoint_id: row.endpoint_id, reason: :gone_410, tenant: tenant}
        )

        finalize_disable(row, "gone_410", config, tenant)

      %Ash.BulkResult{status: :success, records: []} ->
        resolve_disable_endpoint(
          row,
          PrimaryKey.filter(endpoint),
          snapshot,
          switch,
          config,
          tenant
        )

      %Ash.BulkResult{} = result ->
        bulk_failure(result)
    end
  end

  defp optional_snapshot_filter(query, :previous_secret_ref, nil),
    do: Ash.Query.filter(query, is_nil(previous_secret_ref))

  defp optional_snapshot_filter(query, :previous_secret_ref, value),
    do: Ash.Query.filter(query, previous_secret_ref == ^value)

  defp optional_snapshot_filter(query, :legacy_secret_ref, nil),
    do: Ash.Query.filter(query, is_nil(legacy_secret_ref))

  defp optional_snapshot_filter(query, :legacy_secret_ref, value),
    do: Ash.Query.filter(query, legacy_secret_ref == ^value)

  defp optional_snapshot_filter(query, :legacy_previous_secret_ref, nil),
    do: Ash.Query.filter(query, is_nil(legacy_previous_secret_ref))

  defp optional_snapshot_filter(query, :legacy_previous_secret_ref, value),
    do: Ash.Query.filter(query, legacy_previous_secret_ref == ^value)

  defp resolve_disable_endpoint(row, key, snapshot, switch, config, tenant) do
    with_endpoint(
      config[:endpoints],
      key,
      tenant,
      fn -> finalize_disable(row, "gone_410_endpoint_gone", config, tenant) end,
      fn endpoint ->
        resolve_disable_endpoint_state(row, endpoint, snapshot, switch, config, tenant)
      end
    )
  end

  defp resolve_disable_endpoint_state(row, endpoint, snapshot, switch, config, tenant) do
    cond do
      not AshHooks.Endpoint.enabled?(endpoint) ->
        finalize_disable(row, "gone_410_endpoint_already_disabled", config, tenant)

      not endpoint_configuration_matches?(endpoint, snapshot, switch) ->
        finalize_disable(row, "gone_410_endpoint_reconfigured", config, tenant)

      true ->
        {:error, :endpoint_changed}
    end
  end

  defp finalize_disable(row, error, config, tenant) do
    case fenced_update(
           row,
           config,
           :finalize_disable,
           %{error: error},
           [:disable_pending],
           tenant
         ) do
      {:ok, [final]} ->
        summary = {final.response_status, final.response_snippet}
        emit_result(final, summary, :dead_letter, error)

        history = disable_attempt_history(final.endpoint_snapshot)
        record_attempt(final, :dead_letter, error, summary, history, config, tenant)

        :telemetry.execute(
          [:ash_hooks, :delivery, :dead_letter],
          %{},
          %{
            endpoint_id: final.endpoint_id,
            event_uuid: final.event_uuid,
            reason: error,
            response_status: final.response_status
          }
        )

        :ok

      {:ok, []} ->
        {:error, :stale_disable_obligation}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp disable_attempt_history(snapshot) do
    history = (snapshot || %{})["attempt_history"] || %{}

    Map.new([:latency_ms, :signing_key_ref, :response_snippet, :response_headers], fn key ->
      {key, Map.get(history, Atom.to_string(key), Map.get(history, key))}
    end)
  end

  defp endpoint_snapshot(endpoint) do
    switch = endpoint_switch(endpoint.__struct__)

    %{
      "endpoint_pk" => PrimaryKey.encode(endpoint),
      "url" => endpoint.url,
      "secret_ref" => endpoint.secret_ref,
      "previous_secret_ref" => endpoint.previous_secret_ref,
      "legacy_secret_ref" => endpoint.legacy_secret_ref,
      "legacy_previous_secret_ref" => endpoint.legacy_previous_secret_ref,
      "status_attribute" => Atom.to_string(switch),
      "status_value" => Map.get(endpoint, switch)
    }
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp endpoint_switch(resource),
    do: Extension.get_opt(resource, [:endpoint], :status_attribute, nil) || :status

  defp terminalize_exhausted(row, config, tenant) do
    now = now(config)

    query =
      config[:deliveries]
      |> Ash.Query.do_filter(PrimaryKey.filter(row))
      |> Ash.Query.filter(
        dispatch_source == ^row.dispatch_source and
          ^exhausted_ceiling(row, config[:max_attempts])
      )
      |> eligible_exhausted_query(row.status, now)

    result =
      Ash.bulk_update(
        query,
        :mark_send_failed,
        %{
          error: "attempt_ceiling",
          next_attempt_at: nil,
          dead_letter?: true,
          response_status: nil,
          response_snippet: nil
        },
        authorize?: false,
        return_records?: true,
        return_errors?: true,
        strategy: [:atomic],
        tenant: tenant
      )

    case result do
      %Ash.BulkResult{status: :success, records: [final]} ->
        emit_result(final, nil, :dead_letter, "attempt_ceiling")

        :telemetry.execute(
          [:ash_hooks, :delivery, :dead_letter],
          %{},
          %{
            endpoint_id: final.endpoint_id,
            event_uuid: final.event_uuid,
            reason: "attempt_ceiling",
            response_status: nil
          }
        )

        :ok

      %Ash.BulkResult{status: :success, records: []} ->
        {:snooze, 1}

      %Ash.BulkResult{} = result ->
        bulk_failure(result)
    end
  end

  defp eligible_exhausted_query(query, :sending, now),
    do:
      Ash.Query.filter(
        query,
        status == :sending and
          (is_nil(send_lease_expires_at) or send_lease_expires_at <= ^now)
      )

  defp eligible_exhausted_query(query, :failed_retryable, now),
    do:
      Ash.Query.filter(
        query,
        status == :failed_retryable and
          (is_nil(next_attempt_at) or next_attempt_at <= ^now)
      )

  defp eligible_exhausted_query(query, status, _now)
       when status in [:pending, :enqueue_failed],
       do: Ash.Query.filter(query, status == ^status)

  # ────────────────────────── transitions ──────────────────────────

  defp mark_sending(row, config, tenant) do
    now = now(config)
    token = Ash.UUID.generate()

    lease = config[:driver_deadline]

    query =
      config[:deliveries]
      |> Ash.Query.do_filter(PrimaryKey.filter(row))
      |> Ash.Query.filter(
        dispatch_source == ^row.dispatch_source and ^series_ceiling(row, config[:max_attempts])
      )
      |> claimable_state_query(row.status, row.attempt_token, now)
      |> maybe_baseline_fence(row)

    result =
      Ash.bulk_update(
        query,
        :mark_sending,
        %{attempt_token: token, send_lease_expires_at: lease},
        authorize?: false,
        return_records?: true,
        return_errors?: true,
        strategy: [:atomic],
        tenant: tenant
      )

    case result do
      %Ash.BulkResult{status: :success, records: [updated]} -> {:ok, updated}
      %Ash.BulkResult{status: :success, records: []} -> :contended
      %Ash.BulkResult{} = result -> bulk_failure(result)
    end
  end

  defp series_ceiling(row, max_attempts) do
    require Ash.Expr

    if ResourceInfo.attribute(row.__struct__, :resend_baseline) do
      attempts = Ash.Expr.ref(:attempts)
      baseline = Ash.Expr.ref(:resend_baseline)

      Ash.Expr.expr(
        ^attempts - ^baseline < ^max_attempts and ^baseline == ^Map.get(row, :resend_baseline, 0)
      )
    else
      Ash.Expr.expr(^Ash.Expr.ref(:attempts) < ^max_attempts)
    end
  end

  defp exhausted_ceiling(row, max_attempts) do
    require Ash.Expr

    if ResourceInfo.attribute(row.__struct__, :resend_baseline) do
      attempts = Ash.Expr.ref(:attempts)
      baseline = Ash.Expr.ref(:resend_baseline)

      Ash.Expr.expr(
        ^attempts - ^baseline >= ^max_attempts and
          ^baseline == ^Map.get(row, :resend_baseline, 0)
      )
    else
      Ash.Expr.expr(^Ash.Expr.ref(:attempts) >= ^max_attempts)
    end
  end

  # a resend BETWEEN claim and result changes the baseline: the fence must
  # invalidate the stale claim (the same CAS discipline as the token)
  defp maybe_baseline_fence(query, row) do
    if ResourceInfo.attribute(row.__struct__, :resend_baseline) do
      Ash.Query.filter(query, resend_baseline == ^Map.get(row, :resend_baseline, 0))
    else
      query
    end
  end

  defp claimable_state_query(query, status, previous_token, now) do
    query
    |> prior_token_filter(previous_token)
    |> case do
      query when status in [:pending, :enqueue_failed] ->
        Ash.Query.filter(query, status == ^status)

      query when status == :failed_retryable ->
        Ash.Query.filter(
          query,
          status == :failed_retryable and
            (is_nil(next_attempt_at) or next_attempt_at <= ^now)
        )

      query when status == :sending ->
        Ash.Query.filter(
          query,
          status == :sending and
            (is_nil(send_lease_expires_at) or send_lease_expires_at <= ^now)
        )
    end
  end

  defp prior_token_filter(query, nil), do: Ash.Query.filter(query, is_nil(attempt_token))

  defp prior_token_filter(query, token),
    do: Ash.Query.filter(query, attempt_token == ^token)

  # Reconcile writes are NEVER swallowed. A lost terminal write leaves the
  # row recoverable as an expired :sending lease, and the worker must surface
  # the error so Oban can re-drive it.
  defp mark_succeeded(row, response, config, tenant, history) do
    case fenced_update(
           row,
           config,
           :mark_succeeded,
           %{
             response_status: response.status,
             response_snippet: snippet_for(response, config)
           },
           [:sending],
           tenant
         ) do
      {:ok, [_]} ->
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

        record_attempt(row, :succeeded, nil, {response.status, nil}, history, config, tenant)

        :ok

      {:ok, []} ->
        {:snooze, 1}

      {:error, reason} ->
        {:error, {:reconcile_failed, reason}}
    end
  end

  defp retry(row, error, config, tenant, retry_after, summary \\ nil, history \\ nil) do
    if series_attempts(row) >= config[:max_attempts] do
      dead_letter(row, error, config, tenant, summary, history)
    else
      delay = delay_seconds(row, config, retry_after)
      next_at = DateTime.add(now(config), delay, :second)

      case fenced_update(
             row,
             config,
             :mark_send_failed,
             summary_input(summary, %{
               error: error,
               next_attempt_at: next_at,
               dead_letter?: false
             }),
             [:sending],
             tenant
           ) do
        {:ok, [_]} ->
          emit_result(row, summary, :failed_retryable, error)

          record_attempt(row, :failed_retryable, error, summary, history, config, tenant)

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

        {:ok, []} ->
          {:snooze, 1}

        {:error, reason} ->
          {:error, {:reconcile_failed, reason}}
      end
    end
  end

  defp dead_letter(row, error, config, tenant, summary \\ nil, history \\ nil) do
    case fenced_update(
           row,
           config,
           :mark_send_failed,
           summary_input(summary, %{error: error, next_attempt_at: nil, dead_letter?: true}),
           [:sending],
           tenant
         ) do
      {:ok, [_]} ->
        emit_result(row, summary, :dead_letter, error)

        record_attempt(row, :dead_letter, error, summary, history, config, tenant)

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

      {:ok, []} ->
        {:snooze, 1}

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
  defp fenced_update(row, config, action, input, statuses, tenant) do
    now = now(config)

    query =
      config[:deliveries]
      |> Ash.Query.do_filter(PrimaryKey.filter(row))
      |> Ash.Query.filter(dispatch_source == ^row.dispatch_source and status in ^statuses)
      |> maybe_attempt_fence(row, statuses, now)

    query
    |> Ash.bulk_update(action, input,
      authorize?: false,
      return_records?: true,
      return_errors?: true,
      strategy: [:atomic],
      tenant: tenant
    )
    |> case do
      %Ash.BulkResult{status: :success, records: records} -> {:ok, records}
      %Ash.BulkResult{} = result -> bulk_failure(result)
    end
  end

  defp bulk_failure(%Ash.BulkResult{} = result),
    do: {:error, List.first(result.errors || []) || result}

  defp maybe_attempt_fence(query, _row, [:disable_pending], _now), do: query

  defp maybe_attempt_fence(query, row, _statuses, now) do
    Ash.Query.filter(
      query,
      attempt_token == ^row.attempt_token and send_lease_expires_at >= ^now
    )
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
  # fallback), never raise out of the driver.
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
    (config[:now] || fn -> DateTime.utc_now() end).() |> DateTime.truncate(:microsecond)
  end

  # ────────────────────────── snippets + redaction ──────────────────────────

  @doc """
  The default response summary:
  a fixed grammar over the status and one ALLOWLISTED content-type token ;
  never body bytes, never a body-derived digest (a hash is correlation
  material that explains nothing).

      "200 json token=application/json"   # the type was allowlisted
      "200 text token=other"              # anything else collapses to other

  The status is an integer, the kind comes from a fixed vocabulary
  (`json | html | text | xml | binary | other`), and the token is either an
  exact allowlist member or the literal `other`; a hostile Content-Type
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
  The built-in response-body redaction for opt-in capture.

  Normalizes Unicode, decodes encoded text, removes recognized secret patterns
  and control characters, and limits the result to 2,048 bytes. Invalid UTF-8
  returns `[binary]`. Applications must add rules for sensitive values the
  built-in patterns do not recognize.
  """
  @spec redact(term()) :: String.t() | nil
  def redact(body) when is_binary(body) do
    if String.valid?(body) do
      body
      |> decode_fixpoint(@decode_passes)
      |> apply_redaction_patterns()
      # strip control bytes — a hostile NUL would make the post-send
      # ledger write fail on TEXT columns AFTER a successful send
      #
      |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
      |> String.replace(~r/[\r\n]+/, " ")
      |> AshHooks.BoundedText.cap(@snippet_max)
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
        # the combined string re-capped so the 2048 attribute constraint
        # holds WITH the marker inside it — a byte cap bounds codepoints
        # and graphemes alike, in either counting mode
        AshHooks.BoundedText.cap(@captured_prefix <> redact(material), @snippet_max)

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
      out when is_binary(out) -> {:ok, AshHooks.BoundedText.cap(out, @snippet_max)}
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
  # write post-send (the re-send poison class)
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
  # survive)
  defp json_unescape(string) do
    Regex.replace(~r/\\u([0-9a-fA-F]{4})/, string, &escape_to_char/2)
  end

  defp escape_to_char(whole, code) do
    <<String.to_integer(code, 16)::utf8>>
  rescue
    ArgumentError -> whole
  end

  defp apply_redaction_patterns(body) do
    Enum.reduce(redaction_patterns(), body, &String.replace(&2, &1, "[redacted]"))
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
