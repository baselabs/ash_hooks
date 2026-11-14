defmodule AshHooks.EndpointHealth do
  @moduledoc """
  Computes endpoint health from attempt history and applies an optional
  sustained-failure disable policy.

  Latency percentiles use attempts with a recorded duration, including failed
  request attempts. First-attempt successes count successful attempt 1 rows.
  Eventual successes count deliveries with any successful attempt, including
  attempt 1.

  Schedule `stats/2` per endpoint and `sweep/3` per endpoint resource. The
  application owns the sweep schedule and prevents overlapping sweeps.
  The package does not re-enable disabled endpoints.
  """

  require Ash.Expr
  require Ash.Query

  alias AshHooks.{Endpoint, Tenancy}

  @typedoc "One endpoint's trailing-window health."
  @type stats :: %{
          attempts: non_neg_integer(),
          succeeded: non_neg_integer(),
          failed: non_neg_integer(),
          success_rate: float() | nil,
          first_attempt_successes: non_neg_integer(),
          eventual_successes: non_neg_integer(),
          deliveries: non_neg_integer(),
          latency_p50_ms: non_neg_integer() | nil,
          latency_p90_ms: non_neg_integer() | nil,
          latency_p99_ms: non_neg_integer() | nil
        }

  @doc """
  Computes one endpoint's health over the trailing window of its attempt
  rows (requires an `AshHooks.OutboundAttempt` resource).

  Options: `:endpoint_id` (required), `:window_seconds` (default 86,400),
  `:now` (the application clock), `:from`/`:to` (explicit DateTime bounds),
  and `:tenant`. When supplying explicit bounds, provide `:from`; `:to`
  is optional. Supplying `:to` alone can raise during comparison.

      {:ok, %{attempts: 40, success_rate: 0.925, latency_p50_ms: 120, ...}} =
        AshHooks.EndpointHealth.stats(MyApp.Attempt, endpoint_id: endpoint.id)
  """
  @spec stats(module(), keyword()) :: {:ok, stats()} | {:error, term()}
  def stats(attempts_mod, opts \\ []) do
    with {:ok, endpoint_id} <- require_endpoint_id(opts[:endpoint_id]),
         :ok <- validate_bounds(opts),
         {:ok, tenant} <- Tenancy.resolve([attempts_mod], opts[:tenant]),
         {:ok, rows} <- window_attempts(attempts_mod, endpoint_id, opts, tenant) do
      {:ok, compute_stats(rows)}
    end
  end

  @doc """
  Applies the endpoint resource's `auto_disable` policy to enabled endpoints.

  A qualifying endpoint without `disable_warned_at` gets a warning marker and
  `[:ash_hooks, :endpoint, :disable_warning]` telemetry. A later sweep can
  attempt disablement once that marker exists. No minimum warning interval is
  enforced; prevent overlapping sweeps and schedule the desired interval.
  Endpoints below the failure thresholds have their warning marker cleared.

  Disable attempts emit `[:ash_hooks, :endpoint, :disable]` with reason
  `:sustained_failure`. The write result is not checked. The `disabled` count
  reports attempts, not confirmed writes. Read the endpoint to confirm its state.

  Options: `:now` and `:tenant`. Returns `{:ok, %{disabled: n, warned: n}}`.
  """
  @spec sweep(module(), module(), keyword()) ::
          {:ok, %{disabled: non_neg_integer(), warned: non_neg_integer()}} | {:error, term()}
  def sweep(endpoints_mod, attempts_mod, opts \\ []) do
    with {:ok, tenant} <- Tenancy.resolve([endpoints_mod, attempts_mod], opts[:tenant]),
         policy when policy != nil <- Endpoint.auto_disable_policy(endpoints_mod),
         {:ok, endpoints} <- Ash.read(endpoints_mod, authorize?: false, tenant: tenant) do
      # the ONE enabled-check (mapped switch or injected status)
      {disabled, warned} = sweep_endpoints(endpoints, attempts_mod, policy, now(opts), tenant)
      {:ok, %{disabled: disabled, warned: warned}}
    else
      nil -> {:ok, %{disabled: 0, warned: 0}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sweep_endpoints(endpoints, attempts_mod, policy, now, tenant) do
    endpoints
    |> Enum.filter(&Endpoint.enabled?/1)
    |> Enum.reduce({0, 0}, fn endpoint, acc ->
      sweep_one(endpoint, attempts_mod, policy, now, tenant, acc)
    end)
  end

  # The warning-first contract: a disable lands only on a sweep AFTER one
  # that warned. The warned state is DURABLE (`disable_warned_at`, stamped
  # by the warning sweep): the first sweep that sees a qualifying failure
  # warns and stamps — the breaker opens on the next sweep that still
  # sees it. Recovery below the warning band clears the stamp, so a later
  # degradation gets a fresh warning cycle.
  defp sweep_one(endpoint, attempts_mod, policy, now, tenant, {disabled, warned}) do
    from = DateTime.add(now, -policy.failure_window_seconds, :second)

    case window_attempts(attempts_mod, endpoint_id_of(endpoint), [from: from, to: now], tenant) do
      {:ok, rows} ->
        total = length(rows)
        failed = count_failed(rows)
        share = share(failed, total)

        cond do
          total < policy.warning_min_attempts ->
            clear_warned(endpoint, tenant)
            {disabled, warned}

          total >= policy.min_attempts and share >= policy.failure_share ->
            sustain_failure(endpoint, share, total, now, policy, tenant, {disabled, warned})

          share >= policy.warning_share ->
            {disabled, warned + if(warn(endpoint, share, total, now, tenant), do: 1, else: 0)}

          true ->
            clear_warned(endpoint, tenant)
            {disabled, warned}
        end

      {:error, _reason} ->
        # one endpoint's history read failing never stops the sweep
        {disabled, warned}
    end
  end

  # The disable arm: ONLY a previously-warned endpoint opens the breaker
  # — a first qualifying observation warns and stamps; the next sweep
  # that still qualifies disables and clears
  defp sustain_failure(endpoint, share, total, now, policy, tenant, {disabled, warned}) do
    if warned_previously?(endpoint) do
      if DateTime.diff(now, endpoint.disable_warned_at, :microsecond) >=
           policy.warning_interval_seconds * 1_000_000 and disable_sustained(endpoint, tenant) do
        clear_warned(endpoint, tenant)
        {disabled + 1, warned}
      else
        {disabled, warned}
      end
    else
      {disabled, warned + if(warn(endpoint, share, total, now, tenant), do: 1, else: 0)}
    end
  end

  defp warned_previously?(endpoint), do: Map.get(endpoint, :disable_warned_at) != nil

  defp warn(endpoint, share, total, now, tenant) do
    if stamp_warned(endpoint, now, tenant) do
      :telemetry.execute(
        [:ash_hooks, :endpoint, :disable_warning],
        %{},
        %{endpoint_id: endpoint_id_of(endpoint), failure_share: share, attempts: total}
      )

      true
    else
      false
    end
  end

  # A concurrent sweep can win the marker, but only its committed write warns.
  defp stamp_warned(endpoint, now, tenant) do
    if warned_previously?(endpoint) do
      false
    else
      endpoint.__struct__
      |> Ash.Query.do_filter(AshHooks.PrimaryKey.filter(endpoint))
      |> Ash.Query.filter(is_nil(disable_warned_at))
      |> Ash.bulk_update(:mark_disable_warned, %{warned_at: now},
        authorize?: false,
        return_records?: true,
        return_errors?: true,
        strategy: [:atomic],
        tenant: tenant
      )
      |> committed?()
    end
  end

  # the marker clears on disable and on recovery below the warning band —
  # gated on the value this sweep read, so a concurrent sweeper's stamp
  # is never wiped by stale knowledge. Unstamped endpoints write nothing.
  defp clear_warned(endpoint, tenant) do
    if warned_previously?(endpoint) do
      stamped_at = endpoint.disable_warned_at

      _ =
        endpoint.__struct__
        |> Ash.Query.do_filter(AshHooks.PrimaryKey.filter(endpoint))
        |> Ash.Query.filter(disable_warned_at == ^stamped_at)
        |> Ash.bulk_update(:mark_disable_warned, %{warned_at: nil},
          authorize?: false,
          return_records?: false,
          return_errors?: false,
          strategy: [:atomic],
          tenant: tenant
        )

      :ok
    end
  end

  defp disable_sustained(endpoint, tenant) do
    switch =
      Spark.Dsl.Extension.get_opt(endpoint.__struct__, [:endpoint], :status_attribute, nil) ||
        :status

    stamped_at = endpoint.disable_warned_at

    committed =
      endpoint.__struct__
      |> Ash.Query.do_filter(AshHooks.PrimaryKey.filter(endpoint))
      |> Ash.Query.do_filter(%{switch => Map.fetch!(endpoint, switch)})
      |> Ash.Query.filter(disable_warned_at == ^stamped_at)
      |> Ash.bulk_update(:disable, %{},
        authorize?: false,
        return_records?: true,
        return_errors?: true,
        strategy: [:atomic],
        tenant: tenant
      )
      |> committed?()

    if committed do
      :telemetry.execute(
        [:ash_hooks, :endpoint, :disable],
        %{},
        %{endpoint_id: endpoint_id_of(endpoint), reason: :sustained_failure}
      )
    end

    committed
  end

  defp committed?(%Ash.BulkResult{status: :success, records: [_]}), do: true
  defp committed?(_), do: false

  defp count_failed(rows) do
    Enum.count(rows, &(&1.outcome != :succeeded))
  end

  defp share(0, _total), do: 0.0
  defp share(failed, total), do: failed / total

  # The window's attempt rows for one endpoint: the endpoint filter runs
  # in SQL; the TIME bounds apply in memory over the cast DateTime values.
  # A per-endpoint attempt history is a bounded read (this is one
  # endpoint's rows, not the ledger's), and in-memory bounds compare
  # identically on every supported data layer — no storage-format text
  # comparisons anywhere.
  defp window_attempts(attempts_mod, endpoint_id, opts, tenant) do
    {from, to} = bounds(opts)

    endpoint = Ash.Expr.ref(:endpoint_id)
    expression = Ash.Expr.expr(^endpoint == ^endpoint_id)

    attempts_mod
    |> Ash.Query.do_filter(expression)
    |> Ash.read(authorize?: false, tenant: tenant)
    |> case do
      {:ok, rows} ->
        {:ok,
         Enum.filter(rows, fn row ->
           in_window?(row.attempted_at, from, to)
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp in_window?(attempted_at, from, to) do
    DateTime.compare(attempted_at, from) != :lt and
      (is_nil(to) or DateTime.compare(attempted_at, to) != :gt)
  end

  defp validate_bounds(opts) do
    if is_nil(opts[:from]) and not is_nil(opts[:to]), do: {:error, :from_required}, else: :ok
  end

  defp bounds(opts) do
    case {opts[:from], opts[:to]} do
      {nil, nil} ->
        now = now(opts)
        {DateTime.add(now, -(opts[:window_seconds] || 86_400), :second), nil}

      {from, to} ->
        {from, to}
    end
  end

  defp compute_stats(rows) do
    succeeded = Enum.count(rows, &(&1.outcome == :succeeded))
    latencies = rows |> Enum.map(& &1.latency_ms) |> Enum.reject(&is_nil/1) |> Enum.sort()

    deliveries =
      rows
      |> Enum.map(& &1.delivery_pk)
      |> Enum.uniq()
      |> length()

    %{
      attempts: length(rows),
      succeeded: succeeded,
      failed: length(rows) - succeeded,
      success_rate: share(succeeded, length(rows)) |> presence(length(rows)),
      first_attempt_successes: first_attempt_successes(rows),
      eventual_successes: eventual_successes(rows),
      deliveries: deliveries,
      latency_p50_ms: percentile(latencies, 0.50),
      latency_p90_ms: percentile(latencies, 0.90),
      latency_p99_ms: percentile(latencies, 0.99)
    }
  end

  # FIRST-ATTEMPT success: the delivery's attempt 1 succeeded — the
  # number a "how healthy is this endpoint right now" dashboard wants
  defp first_attempt_successes(rows) do
    rows
    |> Enum.filter(&(&1.attempt == 1 and &1.outcome == :succeeded))
    |> Enum.map(& &1.delivery_pk)
    |> Enum.uniq()
    |> length()
  end

  # EVENTUAL success: the delivery succeeded on ANY attempt (the last
  # one for a retried delivery) — the receiver-side experience
  defp eventual_successes(rows) do
    rows
    |> Enum.filter(&(&1.outcome == :succeeded))
    |> Enum.map(& &1.delivery_pk)
    |> Enum.uniq()
    |> length()
  end

  # 0/0 is no evidence, not certainty: an empty window reports nil rates
  defp presence(_share, 0), do: nil
  defp presence(share, _total), do: share

  # nearest-rank percentiles over the sorted observations
  defp percentile([], _rank), do: nil

  defp percentile(sorted, rank) do
    index = max(ceil(rank * length(sorted)), 1) - 1
    Enum.at(sorted, min(index, length(sorted) - 1))
  end

  defp require_endpoint_id(nil) do
    alias AshHooks.Errors.Unknown.UnknownError
    {:error, UnknownError.exception(error: "stats requires :endpoint_id")}
  end

  defp require_endpoint_id(id), do: {:ok, id}

  defp endpoint_id_of(endpoint), do: AshHooks.PrimaryKey.scalar!(endpoint)

  defp now(opts),
    do: opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)
end
