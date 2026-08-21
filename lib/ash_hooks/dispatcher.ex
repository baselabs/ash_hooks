defmodule AshHooks.Dispatcher do
  @moduledoc """
  The outbound fanout driver: one event → every matching subscription's
  endpoint → a durable per-endpoint delivery row (+ an enqueue handoff),
  with per-endpoint isolation — the outbound twin of `AshHooks.Ingress`.

      {:ok, event} = AshHooks.Event.new(type: :order_paid, payload: body)

      AshHooks.dispatch(Order, :order_paid, event, enqueue: {MyRuntime, :enqueue})

  The machine's contract:

    * every matching ENABLED endpoint gets a delivery row unique on
      `{endpoint_id, event_uuid}` — the same pair the Oban job
      uniqueness keys use (ADR-0004, verified against deps/oban 2.23.1:
      `fields: [:args], keys: [...]` matches on a jsonb CONTAINMENT of
      exactly these top-level arg keys, so the enqueue seam's args must
      always carry both);
    * the row persists BEFORE anything else — payload bytes included —
      so a later runtime can sign and send from the ledger of record
      alone;
    * one endpoint's enqueue failure or raise records `:enqueue_failed`
      on ITS row and NEVER stops the others (the fanout-isolation
      guarantee);
    * re-dispatching an `:enqueue_failed` event CLAIMS the row via a
      WHERE-gated `:enqueue_failed → :pending` CAS first — only the
      dispatcher that wins the flip calls the enqueuer, so concurrent
      repairs cannot double-enqueue;
    * with no `:enqueue` configured the rows persist `:pending` and the
      results say `:deferred` — the durable ledger IS the source of
      truth; the delivery runtime slice drives pending rows.

  Global failures (unknown outbound declaration, an invalid event,
  missing DSL module opts, an unreadable subscription set, divergent
  effective signing modes for one endpoint) return `{:error, reason}`
  BEFORE any row is written. Subscriptions are read through the
  consumer's primary read action and endpoints through their resource's
  `get` — both unauthorized, the signature of the inbound machine: the
  dispatch call is the trust boundary for writes, read surfaces stay
  governed by consumer policies (ADR-0005).
  """

  require Ash.Query

  alias AshHooks.Errors.Unknown.UnknownError
  alias AshHooks.{Event, Info, Subscription}
  alias Spark.Dsl.Extension

  @doc """
  Fans one event out to every matching subscription's enabled endpoint.
  Returns `{:ok, results}` — one map per endpoint
  (`%{endpoint_id:, subscription_id:, status:, error:}` with `status` in
  `:created | :duplicate | :deferred | :enqueue_failed | :mark_failed |
  :endpoint_error`) — or `{:error, reason}` for global failures.

  Options:

    * `:enqueue` — the enqueue seam: a 2-arity function
      (`fn delivery, event -> :ok | {:error, term}`) or a `{module, function}`
      pair applied as `apply(module, function, [delivery, event])`. The
      delivery runtime slice's `AshHooks.Delivery` behaviour is its canonical
      implementation; `nil` (the default) persists `:pending` rows and
      returns `:deferred` results.
  """
  @spec dispatch(module(), atom(), Event.t() | term(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def dispatch(resource, name, event, opts \\ []) do
    with {:ok, entity} <- fetch_outbound(resource, name),
         {:ok, event} <- cast_event(event),
         {:ok, subs_mod} <- resolve_module(entity, :subscriptions),
         {:ok, deliv_mod} <- resolve_module(entity, :deliveries),
         {:ok, matches} <- match_subscriptions(subs_mod, event),
         :ok <- check_conflicts(matches, entity) do
      {:ok,
       matches
       |> dedupe_by_endpoint()
       |> Enum.map(&dispatch_one(deliv_mod, event, &1, opts))}
    end
  end

  # ────────────────────────── per-endpoint machine ──────────────────────────

  defp dispatch_one(deliv_mod, event, {subscription, endpoint}, opts) do
    case upsert_row(deliv_mod, event, subscription, endpoint) do
      {:ok, row, :created} ->
        merge_result(endpoint, subscription, enqueue(deliv_mod, row, event, opts))

      {:ok, row, :duplicate} ->
        repair(deliv_mod, event, subscription, endpoint, row, opts)

      {:error, reason} ->
        result(endpoint, subscription, :endpoint_error, reason)
    end
  rescue
    reason -> result(endpoint, subscription, :endpoint_error, error_string(reason))
  end

  # The enqueue-repair path: a duplicate row that died at enqueue gets ONE
  # more attempt per re-dispatch, guarded by the claim-then-enqueue CAS.
  defp repair(deliv_mod, event, subscription, endpoint, row, opts) do
    if row.status == :enqueue_failed and claim_for_enqueue(deliv_mod, row.id) do
      case reload(deliv_mod, row.id) do
        nil ->
          result(endpoint, subscription, :duplicate)

        reloaded ->
          merge_result(endpoint, subscription, enqueue(deliv_mod, reloaded, event, opts))
      end
    else
      result(endpoint, subscription, :duplicate)
    end
  end

  defp upsert_row(deliv_mod, event, subscription, endpoint) do
    id = Ash.UUID.generate()

    input = %{
      id: id,
      event_uuid: event.id,
      event_type: event.type,
      payload: event.payload,
      endpoint_id: endpoint.id,
      subscription_id: subscription.id
    }

    case with_transient_retry(fn ->
           Ash.create(deliv_mod, input, action: :dispatch, authorize?: false)
         end) do
      {:ok, row} -> {:ok, row, if(row.id == id, do: :created, else: :duplicate)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp enqueue(deliv_mod, row, event, opts) do
    case enqueue_result(opts[:enqueue], row, event) do
      :ok ->
        %{status: :created, error: nil}

      :deferred ->
        %{status: :deferred, error: nil}

      {:error, reason} ->
        case mark_enqueue_failed(deliv_mod, row.id, reason) do
          :ok ->
            %{status: :enqueue_failed, error: reason}

          {:error, mark_error} ->
            %{status: :mark_failed, error: {:enqueue, reason, :mark, mark_error}}
        end
    end
  end

  defp result(endpoint, subscription, status, error \\ nil) do
    %{
      endpoint_id: endpoint.id,
      subscription_id: subscription.id,
      status: status,
      error: error
    }
  end

  defp merge_result(endpoint, subscription, %{status: status, error: error}) do
    result(endpoint, subscription, status, error)
  end

  defp enqueue_result(nil, _row, _event), do: :deferred

  # An enqueue seam that RAISES is an enqueue failure like any other —
  # caught HERE (not by dispatch_one's rescue) so it records
  # :enqueue_failed on the row instead of surfacing :endpoint_error.
  defp enqueue_result(enqueuer, row, event) when is_function(enqueuer, 2) do
    case safe_enqueuer(enqueuer, row, event) do
      :ok -> :ok
      {:error, reason} -> {:error, error_string(reason)}
      _other -> {:error, :invalid_enqueue_result}
    end
  end

  defp enqueue_result({m, f}, row, event) when is_atom(m) and is_atom(f) do
    enqueue_result(&apply(m, f, [&1, &2]), row, event)
  end

  defp enqueue_result(_invalid, _row, _event), do: {:error, :invalid_enqueuer}

  defp safe_enqueuer(enqueuer, row, event) do
    enqueuer.(row, event)
  rescue
    reason -> {:error, {:raised, reason}}
  end

  # The repair CAS: WHERE-gated on :enqueue_failed, so of N concurrent
  # re-dispatchers exactly one wins the :pending flip (bulk_update's
  # matched-records count is the win signal — the stale loser re-reads and
  # sees the row someone else already claimed).
  defp claim_for_enqueue(deliv_mod, row_id) do
    result =
      with_transient_retry(fn ->
        deliv_mod
        |> Ash.Query.filter(id == ^row_id and status == :enqueue_failed)
        |> Ash.bulk_update(:requeue, %{},
          authorize?: false,
          return_records?: true,
          return_errors?: true,
          strategy: [:atomic]
        )
      end)

    case result do
      %Ash.BulkResult{status: :success, records: [_]} -> true
      _else -> false
    end
  end

  # Gated on :pending — the state an enqueue attempt owns: a late failure
  # can never overwrite a row a successful enqueue (or the send runtime)
  # already moved on.
  defp mark_enqueue_failed(deliv_mod, row_id, reason) do
    result =
      with_transient_retry(fn ->
        deliv_mod
        |> Ash.Query.filter(id == ^row_id and status == :pending)
        |> Ash.bulk_update(:mark_enqueue_failed, %{error: error_string(reason)},
          authorize?: false,
          return_records?: true,
          return_errors?: true,
          strategy: [:atomic]
        )
      end)

    case result do
      %Ash.BulkResult{status: :success, records: [_]} -> :ok
      %Ash.BulkResult{status: :success, records: []} -> {:error, :stale_row}
      %Ash.BulkResult{errors: [error | _]} -> {:error, error}
      %Ash.BulkResult{} -> {:error, :mark_failed}
    end
  end

  defp reload(deliv_mod, row_id) do
    case with_transient_retry(fn -> Ash.get(deliv_mod, row_id, authorize?: false) end) do
      {:ok, row} -> row
      {:error, _reason} -> nil
    end
  end

  # ────────────────────────── match + validate ──────────────────────────

  defp match_subscriptions(subs_mod, event) do
    endpoint_mod = Extension.get_opt(subs_mod, [:subscription], :endpoint_resource, nil)

    if is_nil(endpoint_mod) do
      {:error,
       UnknownError.exception(
         error:
           "#{inspect(subs_mod)} declares no subscription.endpoint_resource — the dispatcher cannot resolve endpoints"
       )}
    else
      with {:ok, subscriptions} <- read_subscriptions(subs_mod) do
        matches =
          subscriptions
          |> Enum.filter(&Subscription.matches?(&1, event.type))
          |> resolve_endpoints(endpoint_mod)

        {:ok, matches}
      end
    end
  end

  defp read_subscriptions(subs_mod) do
    case with_transient_retry(fn -> Ash.read(subs_mod, authorize?: false) end) do
      {:ok, subscriptions} -> {:ok, subscriptions}
      {:error, error} -> {:error, error}
    end
  end

  # Endpoint resolution is per-subscription isolation: a gone/unreadable
  # endpoint row skips THAT subscription without stopping the fanout.
  defp resolve_endpoints(subscriptions, endpoint_mod) do
    subscriptions
    |> Enum.reduce([], fn subscription, acc ->
      case Ash.get(endpoint_mod, subscription.endpoint_id, authorize?: false) do
        {:ok, %{status: :enabled} = endpoint} -> [{subscription, endpoint} | acc]
        _skipped -> acc
      end
    end)
    |> Enum.reverse()
  end

  defp check_conflicts(matches, entity) do
    matches
    |> Enum.group_by(fn {subscription, _endpoint} -> subscription.endpoint_id end)
    |> Enum.reduce_while(:ok, fn {_endpoint_id, pairs}, :ok ->
      modes =
        MapSet.new(pairs, fn {subscription, _endpoint} ->
          subscription.signing_mode || entity.signing_mode || :standard
        end)

      if MapSet.size(modes) > 1 do
        {:halt, {:error, :conflicting_subscriptions}}
      else
        {:cont, :ok}
      end
    end)
  end

  # Deterministic order (uuid sort), one entry per endpoint: the first
  # subscription in sort order carries the row's subscription_id.
  defp dedupe_by_endpoint(matches) do
    matches
    |> Enum.sort_by(fn {subscription, _endpoint} ->
      {subscription.endpoint_id, subscription.id}
    end)
    |> Enum.uniq_by(fn {subscription, _endpoint} -> subscription.endpoint_id end)
  end

  # ────────────────────────── resolution ──────────────────────────

  defp fetch_outbound(resource, name) do
    case Info.outbound(resource, name) do
      nil ->
        {:error,
         UnknownError.exception(
           error:
             "no outbound #{inspect(name)} declaration on #{inspect(resource)} — add one under `webhooks`"
         )}

      entity ->
        {:ok, entity}
    end
  end

  defp cast_event(%Event{} = event), do: {:ok, event}

  defp cast_event(_other),
    do:
      {:error,
       UnknownError.exception(
         error: "event must be an %AshHooks.Event{} — build one with AshHooks.Event.new/1"
       )}

  defp resolve_module(entity, key) do
    case Map.get(entity, key) do
      nil ->
        {:error,
         UnknownError.exception(
           error:
             "the outbound #{inspect(entity.name)} declaration is missing its #{inspect(key)} resource module — set `#{key}(Module)` under `outbound`"
         )}

      module when is_atom(module) ->
        {:ok, module}

      _other ->
        {:error,
         UnknownError.exception(error: "outbound #{inspect(key)} must be a resource module")}
    end
  end

  defp error_string({:raised, reason}), do: error_string(reason)
  defp error_string(term) when is_binary(term), do: String.slice(term, 0, 255)
  defp error_string(term) when is_atom(term), do: Atom.to_string(term)

  defp error_string(%{__exception__: true} = exception),
    do: exception |> Exception.message() |> String.slice(0, 255)

  defp error_string(_term), do: "unclassified"

  # ────────────────────────── transient contention retry ──────────────────────────
  # The inbound machine's bounded busy/locked retry (ADR-0003's sqlite
  # probes), ported in substance: concurrent dispatchers on the best-effort
  # sqlite leg contend for the single write lock, and the dispatcher's ops
  # are idempotent or CAS-gated, so a bounded wall-clock retry converts
  # transient contention into convergence instead of an :endpoint_error.
  # Classified NARROWLY by exqlite's error text — other data layers see
  # zero behavior change.
  @transient_retry_deadline_ms 2_000
  @transient_retry_spacing_ms 100
  @transient_retry_jitter_ms 50

  defp with_transient_retry(fun),
    do: with_transient_retry(fun, System.monotonic_time(:millisecond))

  defp with_transient_retry(fun, started_at) do
    result = fun.()

    if transient_retryable?(result) and
         System.monotonic_time(:millisecond) - started_at < @transient_retry_deadline_ms do
      Process.sleep(@transient_retry_spacing_ms + :rand.uniform(@transient_retry_jitter_ms))
      with_transient_retry(fun, started_at)
    else
      result
    end
  end

  defp transient_retryable?({:error, error}), do: transient_sqlite_contention?(error)

  defp transient_retryable?(%Ash.BulkResult{status: :error, errors: [_ | _] = errors}),
    do: Enum.all?(errors, &transient_sqlite_contention?/1)

  defp transient_retryable?(_other), do: false

  defp transient_sqlite_contention?(%Ash.Error.Unknown{} = error) do
    Enum.any?(error.errors, &transient_sqlite_contention?/1)
  end

  defp transient_sqlite_contention?(%Ash.Error.Unknown.UnknownError{error: inner}) do
    inner = to_string(inner)
    String.contains?(inner, "Exqlite.Error") and contentiously_busy?(inner)
  end

  defp transient_sqlite_contention?(_other), do: false

  defp contentiously_busy?(inner) do
    down = String.downcase(inner)
    String.contains?(down, "database busy") or String.contains?(down, "database is locked")
  end
end
