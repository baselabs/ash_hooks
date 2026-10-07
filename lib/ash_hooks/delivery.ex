defmodule AshHooks.Delivery do
  @moduledoc """
  Drives one durable outbound delivery through signing, HTTP, and result
  persistence. It uses your resource modules and configured HTTP adapter.
  `AshHooks.Worker` adds an Oban trigger; this driver also works without Oban.

  The delivery row owns retry policy: the
  driver refuses to re-send `:succeeded`/`:dead_letter` rows, waits on
  `next_attempt_at`, counts `attempts` against the ceiling, and honors
  `Retry-After` (bounded). Oban is the durable trigger — `{:snooze, s}`
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

    * 2xx → `:succeeded` (status + allowlisted content-type summary — no
      body bytes by default; a per-call `snippet_capture: true` config
      persists a bounded, redacted body marked `[captured]`)
    * 408/429 → retryable, `Retry-After` when present (integer seconds or
      HTTP-date; clamped `[1, retry_after_cap]`), else backoff
    * 410 → `:disable_pending`, then conditional endpoint disable and `:dead_letter`
    * other 4xx → `:dead_letter` (client errors do not self-heal)
    * 3xx → `:dead_letter` (`redirect_refused` — never followed)
    * 5xx / transport error / secret-resolution failure → retryable
      backoff
    * send-time SSRF refusal / disabled-or-gone endpoint → `:dead_letter`

  Backoff: `min(base · 2^min(attempts, 16), max_backoff)` seconds plus
  `:rand.uniform(delay)` jitter, re-clamped — always ≥ 1 second.

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
  Retention hook: deletes TERMINAL delivery rows (`:succeeded`,
  `:dead_letter`) older than `older_than`, by the resource's
  `inserted_at` (add Ash `timestamps()` to the resource and its
  migration). Non-terminal rows are never deleted. Returns
  `{:ok, deleted_count}`, or `{:error, error}` when the resource lacks
  `inserted_at` — the same error contract as `AshHooks.Ingress.prune/2`.

  `:tenant` scopes the sweep (required on multitenant resources — a
  tenant-less global sweep over them is the named
  `{:error, :tenant_required}` before any data access).
  `:batch_size` defaults to 500 and accepts integers from 1 through 5,000;
  invalid values return `{:error, :invalid_batch_size}`.
  """
  @spec prune(module(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def prune(deliv_mod, opts) do
    older_than = DateTime.truncate(Keyword.fetch!(opts, :older_than), :microsecond)

    with {:ok, tenant} <- Tenancy.resolve([deliv_mod], opts[:tenant]) do
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
          prune!(deliv_mod, older_than, tenant, Keyword.get(opts, :batch_size, 500))

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

  defp prune!(deliv_mod, older_than, tenant, batch_size)
       when is_integer(batch_size) and batch_size > 0 and batch_size <= 5_000 do
    prune_batch(deliv_mod, older_than, tenant, batch_size, 0)
  end

  defp prune!(_deliv_mod, _older_than, _tenant, _batch_size),
    do: {:error, :invalid_batch_size}

  defp prune_batch(deliv_mod, older_than, tenant, batch_size, total) do
    require Ash.Query

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
      %Ash.BulkResult{status: :success, records: []} ->
        {:ok, total}

      %Ash.BulkResult{status: :success, records: rows} when length(rows) < batch_size ->
        {:ok, total + length(rows)}

      %Ash.BulkResult{status: :success, records: rows} ->
        prune_batch(deliv_mod, older_than, tenant, batch_size, total + length(rows))

      %Ash.BulkResult{} = result ->
        bulk_failure(result)
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
  it as the tenant on every data call — a worker restart or replica
  handoff recovers full tenant context from args alone.

  Returns `:ok` (terminal or attempted-to-terminal), `{:snooze, seconds}`
  (retry later), or `{:error, term}` for a broken trigger (row missing →
  `:ok`; the durable row is the record — a missing row is a completed or
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
  `:snippet_capture`, `:snippet_redactor`, and `:now` customize the documented
  seams.

  Set `:max_attempts` here to configure the delivery row's ceiling. The worker
  macro calls this option `:delivery_max_attempts`; its own `:max_attempts`
  configures Oban's job attempts. Other retry option names are the same.
  """
  @spec run(map(), keyword()) :: :ok | {:snooze, pos_integer()} | {:error, term()}
  def run(args, config) when is_map(args) do
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
           Tenancy.resolve([config[:deliveries], config[:endpoints]], value(args, :tenant)),
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
    if row.attempts >= config[:max_attempts] do
      terminalize_exhausted(row, config, tenant)
    else
      claim_then_attempt(row, config, tenant)
    end
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
    # send-time re-check: full DNS re-resolution by default (ADR-0005);
    # the seam is injectable so deterministic tests use the
    # literal-only variant
    check = config[:ssrf_check] || (&AshHooks.Ssrf.safe_url?/1)

    if check.(endpoint.url) do
      send(row, endpoint, config, tenant)
    else
      dead_letter(row, "unsafe_destination", config, tenant)
    end
  end

  # ────────────────────────── the send ──────────────────────────

  defp send(row, endpoint, config, tenant) do
    :telemetry.execute(
      [:ash_hooks, :delivery, :attempt],
      %{},
      %{
        endpoint_id: PrimaryKey.scalar!(endpoint),
        event_uuid: row.event_uuid,
        attempts: row.attempts
      }
    )

    adapter = config[:http] || AshHooks.Http.Bounded

    request = if is_function(adapter, 5), do: adapter, else: &adapter.request/5

    # adapter opts seam (test listeners' validate_destination: false; real
    # consumers' timeout overrides and a pinned :cacerts trust bundle for
    # private-CA endpoints). Consumer-trusted config like :ssrf_check: it
    # CAN disable the adapter's destination pin — the driver's send-time
    # check above is the residual guarantee, not a full replacement
    adapter_opts = config[:http_opts] || []

    with {:ok, headers} <- signing_headers(row, endpoint, config, tenant),
         {:ok, response} <-
           send_request(request, endpoint, headers, row, adapter_opts) do
      record(row, endpoint, response, config, tenant)
    else
      # a pin-time SSRF refusal is a caught rebinding flip — terminal, per
      # the classification table (never burn the retry ceiling on it)
      {:error, :unsafe_destination} ->
        dead_letter(row, "unsafe_destination", config, tenant)

      {:error, reason} ->
        retry(row, error_string(reason), config, tenant, nil)
    end
  end

  # an adapter RAISE must not crash the job out of the row-owned policy —
  # classify it as a retryable transport failure
  defp send_request(request, endpoint, headers, row, adapter_opts) do
    request.(:post, endpoint.url, headers, payload_bytes(row), adapter_opts)
  rescue
    reason -> {:error, {:adapter_crash, error_string(reason)}}
  end

  # the exact-bytes column's name is consumer-configurable (`payload_attribute`,
  # H1) — every runtime read goes through the row's own resource config
  defp payload_bytes(row), do: Map.get(row, AshHooks.Info.payload_attribute(row.__struct__))

  defp record(row, _endpoint, %{status: status} = response, config, tenant)
       when status in 200..299 do
    mark_succeeded(row, response, config, tenant)
  end

  # The 410 disable rides the ROW's tenant: a cross-tenant 410 (org_b's
  # worker seeing org_a's endpoint id) cannot even resolve org_a's
  # endpoint (the tenant-scoped fetch dead-letters it as endpoint_gone
  # first), and the disable write itself is tenant-filtered. The matched
  # count is checked — a zero-match "success" (the endpoint vanished
  # between fetch and write) is surfaced, never counted as a completed
  # circuit-break.
  defp record(row, endpoint, %{status: 410} = response, config, tenant) do
    {status, snippet} = failure_summary(response)

    case fenced_update(
           row,
           config,
           :mark_disable_pending,
           %{
             response_status: status,
             response_snippet: snippet,
             endpoint_snapshot: endpoint_snapshot(endpoint)
           },
           [:sending],
           tenant
         ) do
      {:ok, [pending]} -> complete_disable(pending, config, tenant)
      {:ok, []} -> {:snooze, 1}
      {:error, reason} -> {:error, {:reconcile_failed, reason}}
    end
  end

  defp record(row, _endpoint, %{status: status} = response, config, tenant)
       when status in [408, 429] do
    retry(
      row,
      "http_#{status}",
      config,
      tenant,
      retry_after(response, config),
      failure_summary(response)
    )
  end

  defp record(row, _endpoint, %{status: status} = response, config, tenant)
       when status in 300..399 do
    dead_letter(row, "redirect_refused_#{status}", config, tenant, failure_summary(response))
  end

  defp record(row, _endpoint, %{status: status} = response, config, tenant)
       when status in 400..499 do
    dead_letter(row, "http_#{status}", config, tenant, failure_summary(response))
  end

  defp record(row, _endpoint, %{status: status} = response, config, tenant) do
    retry(row, "http_#{status}", config, tenant, nil, failure_summary(response))
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
        dispatch_source == ^row.dispatch_source and attempts >= ^config[:max_attempts]
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
        dispatch_source == ^row.dispatch_source and attempts < ^config[:max_attempts]
      )
      |> claimable_state_query(row.status, row.attempt_token, now)

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
  defp mark_succeeded(row, response, config, tenant) do
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

        :ok

      {:ok, []} ->
        {:snooze, 1}

      {:error, reason} ->
        {:error, {:reconcile_failed, reason}}
    end
  end

  defp retry(row, error, config, tenant, retry_after, summary \\ nil) do
    if row.attempts >= config[:max_attempts] do
      dead_letter(row, error, config, tenant, summary)
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

  defp dead_letter(row, error, config, tenant, summary \\ nil) do
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
