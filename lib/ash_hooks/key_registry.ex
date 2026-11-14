defmodule AshHooks.KeyRegistry do
  @moduledoc """
  Durable disposal obligations for opaque webhook keys on a host Ash resource.

  Use this extension on a resource backed by AshPostgres or AshSqlite, with
  the same mutate repo and attribute tenancy as its custody owners. The host
  owns migrations, policies and scheduling. References are globally unique
  `ahk_` UUIDv7 values, and each occupies one owner slot only.

  Schedule `sweep/2` beside the endpoint lifecycle sweep for every tenant.
  Issued references time out after `issue_timeout` seconds (900 by default);
  configure this longer than the custodian's store timeout. Committed retired
  references are destroyed outside transactions using their stored canonical
  `custody_tenant`, even when the owner has been deleted.

  Only `:ok` marks a reference destroyed. An unavailable custodian is retried
  with exponential backoff capped at one hour. Other answers park the obligation
  in `:destroy_failed` with a fixed classification and emit
  `[:ash_hooks, :key_registry, :destroy_failed]`, with `count: 1` and metadata
  `registry`, `ref`, and `reason`. Backend answers are never stored or emitted.
  Operators inspect `pending/2`, repair the cause, then call `rearm/3`.
  `destroy_generation` fences results that were in flight before rearming.
  `prune/2` removes destroyed audit rows only; custody tombstones remain in
  the custodian for the life of its store.

  These functions perform system operations with `authorize?: false`.
  Authorize application callers before exposing them.
  """

  alias AshHooks.KeyRegistry.{Storage, Transitions}
  alias AshHooks.{PrimaryKey, Tenancy}
  alias Spark.Dsl.Extension
  require Ash.Query
  import Bitwise, only: [<<<: 2]

  @section %Spark.Dsl.Section{
    name: :key_registry,
    describe: "Durable key disposal and crash recovery.",
    schema: [
      issue_timeout: [
        type: :pos_integer,
        default: 900,
        doc:
          "Seconds before an unattached issued reference is retired. Must exceed the custodian's store timeout; defaults to 15 minutes."
      ]
    ]
  }

  @doc """
  Reconciles owners, retires expired issues and destroys eligible references.

  Options: `:tenant` and `:now` (UTC clock). Reads use batches of 100 rows.
  Each transition commits in its own bounded transaction. Custody destruction
  runs outside transactions. Refuses an enclosing transaction with
  `{:error, :inside_transaction}`. Returns `{:ok, counts}` including the
  current number of `:destroy_failed` rows.
  """
  def sweep(registry, opts \\ []) do
    with :ok <- Transitions.outside_transaction(registry),
         {:ok, tenant} <- Tenancy.resolve([registry], opts[:tenant]) do
      now = Transitions.now(opts)
      timeout = Extension.get_opt(registry, [:key_registry], :issue_timeout, 900)

      issued = registry |> Storage.query() |> Ash.Query.filter(state == :issued)
      attached = registry |> Storage.query() |> Ash.Query.filter(state == :attached)
      retired = registry |> Storage.query() |> Ash.Query.filter(state == :retired)
      retire = fn row, counts -> retire_row(registry, row, tenant, now, timeout, counts) end
      destroy = fn row, counts -> destroy_row(registry, row, tenant, now, counts) end

      with {:ok, counts} <- scan(issued, tenant, retire, %{destroyed: 0, retired: 0}),
           {:ok, counts} <- scan(attached, tenant, retire, counts),
           {:ok, counts} <- scan(retired, tenant, destroy, counts),
           {:ok, failed} <- pending(registry, tenant: tenant) do
        {:ok, Map.put(counts, :destroy_failed, length(failed))}
      end
    end
  end

  @doc "Lists final destruction failures for the supplied `:tenant`."
  def pending(registry, opts \\ []) do
    with {:ok, tenant} <- Tenancy.resolve([registry], opts[:tenant]) do
      Storage.phase(registry, registry, tenant, fn ->
        registry
        |> Storage.query()
        |> Ash.Query.filter(state == :destroy_failed)
        |> Ash.read(authorize?: false, tenant: tenant)
      end)
    end
  end

  @doc """
  Re-arms a failed reference after its cause has been repaired.

  Accepts `:tenant`. Increments `destroy_generation`, clears the failure and
  retry timing, and resets attempts. Returns `{:error, :not_destroy_failed}`
  if another writer already moved the row.
  """
  def rearm(registry, ref, opts \\ []) do
    with {:ok, tenant} <- Tenancy.resolve([registry], opts[:tenant]) do
      Storage.phase(registry, registry, tenant, fn -> rearm_in_phase(registry, ref, tenant) end)
    end
  end

  defp rearm_in_phase(registry, ref, tenant) do
    query =
      registry |> Storage.query() |> Ash.Query.filter(ref == ^ref and state == :destroy_failed)

    with {:ok, row} <- Ash.read_one(query, authorize?: false, tenant: tenant),
         {:ok, rows} <- rearm_rows(registry, row, query, tenant) do
      case rows do
        [rearmed] -> {:ok, rearmed}
        [] -> {:error, :not_destroy_failed}
      end
    end
  end

  defp rearm_rows(_registry, nil, _query, _tenant), do: {:ok, []}

  defp rearm_rows(registry, row, query, tenant) do
    with :ok <- Storage.check(registry, row.owner_resource) do
      query = Ash.Query.filter(query, destroy_generation == ^row.destroy_generation)

      Transitions.cas(
        query,
        %{
          state: :retired,
          destroy_generation: row.destroy_generation + 1,
          attempts: 0,
          next_attempt_at: nil,
          last_error: nil
        },
        tenant
      )
    end
  end

  @doc """
  Removes destroyed audit rows older than the required `:before` UTC timestamp.

  Accepts `:tenant`. Active, retired and failed obligations are never pruned.
  Returns `{:ok, count}`. This does not prune the custodian's tombstones.
  """
  def prune(registry, opts) do
    before = Keyword.fetch!(opts, :before)

    with {:ok, tenant} <- Tenancy.resolve([registry], opts[:tenant]) do
      query =
        registry
        |> Storage.query()
        |> Ash.Query.filter(state == :destroyed and updated_at < ^before)

      scan(query, tenant, &prune_row(registry, &1, tenant, &2), 0)
    end
  end

  defp prune_row(registry, row, tenant, count) do
    with {:ok, :ok} <-
           Storage.phase(registry, row.owner_resource, tenant, fn ->
             Ash.destroy(row,
               action: :prune_keys,
               authorize?: false,
               tenant: tenant,
               context: Storage.context(registry)
             )
           end),
         do: {:ok, count + 1}
  end

  defp retire_row(registry, row, tenant, now, timeout, counts) do
    with {:ok, retired} <-
           Storage.phase(registry, row.owner_resource, tenant, fn ->
             retire_in_phase(registry, row, tenant, now, timeout)
           end),
         do: {:ok, Map.update!(counts, :retired, &(&1 + retired))}
  end

  defp retire_in_phase(registry, row, tenant, now, timeout) do
    with {:ok, retire?} <- needs_retirement?(row, tenant, now, timeout) do
      retire_matching(registry, row, tenant, now, retire?)
    end
  end

  defp retire_matching(_registry, _row, _tenant, _now, false), do: {:ok, 0}

  defp retire_matching(registry, row, tenant, now, true) do
    query =
      registry |> Storage.query() |> Ash.Query.filter(ref == ^row.ref and state == ^row.state)

    with {:ok, rows} <- Transitions.cas(query, %{state: :retired, destroy_after: now}, tenant),
         do: {:ok, length(rows)}
  end

  defp destroy_row(registry, row, tenant, now, counts) do
    with :ok <- Storage.check(registry, row.owner_resource) do
      if due?(row.destroy_after, now) and due?(row.next_attempt_at, now) do
        result = Storage.custodian(row.owner_resource).destroy(row.ref, row.custody_tenant)
        apply_destroy_result(registry, row, tenant, now, result, counts)
      else
        {:ok, counts}
      end
    end
  end

  defp needs_retirement?(%{state: :issued} = row, _tenant, now, timeout),
    do: {:ok, DateTime.compare(row.issued_at, DateTime.add(now, -timeout)) == :lt}

  defp needs_retirement?(%{state: :attached} = row, tenant, _now, _timeout) do
    with {:ok, key} <- PrimaryKey.decode(row.owner_resource, row.owner_key),
         {:ok, owner} <-
           row.owner_resource
           |> Storage.query()
           |> Ash.Query.do_filter(key)
           |> Ash.read_one(authorize?: false, tenant: tenant) do
      {:ok,
       is_nil(owner) or
         not Enum.any?(Transitions.slots(row.owner_resource), fn {ref, kind} ->
           Map.get(owner, ref) == row.ref and not is_nil(Map.get(owner, kind))
         end)}
    end
  end

  defp apply_destroy_result(registry, row, tenant, now, result, counts) do
    {state, values} = destroy_values(row, now, result)

    with {:ok, rows} <-
           Storage.phase(registry, row.owner_resource, tenant, fn ->
             query =
               registry
               |> Storage.query()
               |> Ash.Query.filter(
                 ref == ^row.ref and state == :retired and
                   destroy_generation == ^row.destroy_generation
               )

             Transitions.cas(query, Map.put(values, :state, state), tenant)
           end) do
      report_destroy_failure(registry, row, state, values, rows)

      {:ok,
       if(rows != [] and state == :destroyed,
         do: Map.update!(counts, :destroyed, &(&1 + 1)),
         else: counts
       )}
    end
  end

  defp report_destroy_failure(registry, row, :destroy_failed, values, [_ | _]) do
    reason = if values.last_error == "tenant_mismatch", do: :tenant_mismatch, else: :unclassified

    :telemetry.execute([:ash_hooks, :key_registry, :destroy_failed], %{count: 1}, %{
      registry: registry,
      ref: row.ref,
      reason: reason
    })
  end

  defp report_destroy_failure(_registry, _row, _state, _values, _rows), do: :ok

  defp destroy_values(_row, _now, :ok), do: {:destroyed, %{last_error: nil, next_attempt_at: nil}}

  defp destroy_values(row, now, {:error, :unavailable}) do
    delay = min(3_600, 1 <<< min(row.attempts, 12))

    {:retired,
     %{
       attempts: row.attempts + 1,
       next_attempt_at: DateTime.add(now, delay),
       last_error: "key_unavailable"
     }}
  end

  defp destroy_values(_row, _now, {:error, :tenant_mismatch}),
    do: {:destroy_failed, %{last_error: "tenant_mismatch"}}

  defp destroy_values(_row, _now, _result), do: {:destroy_failed, %{last_error: "unclassified"}}

  defp due?(nil, _now), do: true
  defp due?(at, now), do: DateTime.compare(at, now) != :gt

  defp scan(query, tenant, fun, acc, cursor \\ nil) do
    page = if cursor, do: Ash.Query.filter(query, ref > ^cursor), else: query

    page =
      page |> Ash.Query.sort(ref: :asc) |> Ash.Query.limit(100)

    with {:ok, rows} <-
           Storage.phase(query.resource, query.resource, tenant, fn ->
             Ash.read(page, authorize?: false, tenant: tenant)
           end) do
      scan_rows(query, tenant, fun, acc, rows)
    end
  end

  defp scan_rows(_query, _tenant, _fun, acc, []), do: {:ok, acc}

  defp scan_rows(query, tenant, fun, acc, rows) do
    with {:ok, acc} <- Enum.reduce_while(rows, {:ok, acc}, &scan_step(&1, &2, fun)) do
      scan(query, tenant, fun, acc, List.last(rows).ref)
    end
  end

  defp scan_step(row, {:ok, acc}, fun) do
    case fun.(row, acc) do
      {:ok, acc} -> {:cont, {:ok, acc}}
      error -> {:halt, error}
    end
  end

  use Spark.Dsl.Extension,
    sections: [@section],
    transformers: [AshHooks.KeyRegistry.Transformers.AddRegistry],
    verifiers: [AshHooks.KeyRegistry.Verifiers.Storage, AshHooks.Verifiers.MultitenancyNoBypass]
end
