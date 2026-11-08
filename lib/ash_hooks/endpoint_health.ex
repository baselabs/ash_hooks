defmodule AshHooks.EndpointHealth do
  @moduledoc """
  Endpoint health over the attempt history, and the sustained-failure
  auto-disable policy.

  `stats/2` computes one endpoint's trailing-window health from its
  attempt rows: the success rate and nearest-rank latency percentiles
  (p50/p90/p99, in milliseconds, over the attempts that reached the
  wire). `sweep/3` applies the endpoint resource's `auto_disable` policy
  (a configurable duration and failure share, beside the existing 410
  rule): an endpoint whose window meets the failure share with the
  minimum evidence is DISABLED through the same durable switch the 410
  rule uses, after a warning fired first at the warning thresholds.
  Re-enabling is an explicit application action — the package never
  re-enables.

  Schedule both alongside your retention sweeps (an Oban cron, a mix
  task): `stats/2` per endpoint page, `sweep/3` per endpoint resource.
  """

  require Ash.Expr

  alias AshHooks.{Endpoint, Tenancy}

  @typedoc "One endpoint's trailing-window health."
  @type stats :: %{
          attempts: non_neg_integer(),
          succeeded: non_neg_integer(),
          failed: non_neg_integer(),
          success_rate: float() | nil,
          latency_p50_ms: non_neg_integer() | nil,
          latency_p90_ms: non_neg_integer() | nil,
          latency_p99_ms: non_neg_integer() | nil
        }

  @doc """
  Computes one endpoint's health over the trailing window of its attempt
  rows (requires an `AshHooks.OutboundAttempt` resource).

  Options: `:endpoint_id` (required), `:window_seconds` (default 86,400),
  `:now` (the application clock), `:from`/`:to` (explicit `DateTime`
  bounds instead of the trailing window), and `:tenant` (the tenancy
  pre-flight applies).

      {:ok, %{attempts: 40, success_rate: 0.925, latency_p50_ms: 120, ...}} =
        AshHooks.EndpointHealth.stats(MyApp.Attempt, endpoint_id: endpoint.id)
  """
  @spec stats(module(), keyword()) :: {:ok, stats()} | {:error, term()}
  def stats(attempts_mod, opts \\ []) do
    with {:ok, endpoint_id} <- require_endpoint_id(opts[:endpoint_id]),
         {:ok, tenant} <- Tenancy.resolve([attempts_mod], opts[:tenant]),
         {:ok, rows} <- window_attempts(attempts_mod, endpoint_id, opts, tenant) do
      {:ok, compute_stats(rows)}
    end
  end

  @doc """
  Applies the endpoint resource's `auto_disable` policy to every enabled
  endpoint, from the attempt history:

    * an endpoint whose trailing window meets `:failure_share` with at
      least `:min_attempts` of evidence is disabled through the same
      durable switch the 410 rule uses, and
      `[:ash_hooks, :endpoint, :disable]` fires with
      `reason: :sustained_failure`;
    * an endpoint that meets the share with less evidence (the warning
      thresholds) emits `[:ash_hooks, :endpoint, :disable_warning]`
      (`failure_share` in the metadata) and stays enabled — the notify
      surface gets its chance before the breaker opens.

  Resources without an `auto_disable` section are skipped wholesale.
  Options: `:now`, `:tenant`. Returns `{:ok, %{disabled: n, warned: n}}`.
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

  defp sweep_one(endpoint, attempts_mod, policy, now, tenant, {disabled, warned}) do
    from = DateTime.add(now, -policy.failure_window_seconds, :second)

    case window_attempts(attempts_mod, endpoint_id_of(endpoint), [from: from, to: now], tenant) do
      {:ok, rows} ->
        total = length(rows)
        failed = count_failed(rows)

        cond do
          total < policy.warning_min_attempts ->
            {disabled, warned}

          total >= policy.min_attempts and share(failed, total) >= policy.failure_share ->
            disable_sustained(endpoint, tenant)
            {disabled + 1, warned}

          share(failed, total) >= policy.warning_share ->
            :telemetry.execute(
              [:ash_hooks, :endpoint, :disable_warning],
              %{},
              %{
                endpoint_id: endpoint_id_of(endpoint),
                failure_share: share(failed, total),
                attempts: total
              }
            )

            {disabled, warned + 1}

          true ->
            {disabled, warned}
        end

      {:error, _reason} ->
        # one endpoint's history read failing never stops the sweep
        {disabled, warned}
    end
  end

  defp disable_sustained(endpoint, tenant) do
    _ =
      endpoint.__struct__
      |> Ash.Query.do_filter(AshHooks.PrimaryKey.filter(endpoint))
      |> Ash.bulk_update(:disable, %{},
        authorize?: false,
        return_records?: false,
        return_errors?: false,
        strategy: [:atomic],
        tenant: tenant
      )

    :telemetry.execute(
      [:ash_hooks, :endpoint, :disable],
      %{},
      %{endpoint_id: endpoint_id_of(endpoint), reason: :sustained_failure}
    )
  end

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

    %{
      attempts: length(rows),
      succeeded: succeeded,
      failed: length(rows) - succeeded,
      success_rate: share(succeeded, length(rows)) |> presence(length(rows)),
      latency_p50_ms: percentile(latencies, 0.50),
      latency_p90_ms: percentile(latencies, 0.90),
      latency_p99_ms: percentile(latencies, 0.99)
    }
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
