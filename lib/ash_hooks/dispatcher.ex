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
      delivery runtime `AshHooks.Delivery.run/2` via the worker macro is its
      canonical implementation; `nil` (the default) persists `:pending` rows
      and returns `:deferred` results.
  """
  @spec dispatch(module(), atom(), Event.t() | term(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def dispatch(resource, name, event, opts \\ []) do
    with {:ok, entity} <- fetch_outbound(resource, name),
         {:ok, event} <- cast_event(event),
         :ok <- check_type_alignment(name, event),
         {:ok, subs_mod} <- resolve_module(entity, :subscriptions),
         {:ok, deliv_mod} <- resolve_module(entity, :deliveries),
         {:ok, matches, error_entries} <- match_subscriptions(subs_mod, event),
         :ok <- check_conflicts(matches, entity) do
      {:ok,
       error_entries ++
         (matches
          |> dedupe_by_endpoint()
          |> Enum.map(&dispatch_one(deliv_mod, event, &1, opts, entity)))}
    end
  end

  # The declaration resolves configuration (resource modules, signing-mode
  # default); the event's type routes subscriptions. Letting the two
  # diverge routes one declaration's resources at another type's
  # subscribers — fail closed on the mismatch (cross-vendor finding).
  defp check_type_alignment(name, %Event{type: type}) do
    if type == Atom.to_string(name) do
      :ok
    else
      {:error,
       UnknownError.exception(
         error:
           "event type #{inspect(type)} does not match the outbound #{inspect(name)} declaration — dispatch through the declaration named for the type"
       )}
    end
  end

  # ────────────────────────── per-endpoint machine ──────────────────────────

  defp dispatch_one(deliv_mod, event, {subscription, endpoint}, opts, entity) do
    case upsert_row(deliv_mod, event, subscription, endpoint, entity) do
      {:ok, row, :created} ->
        merge_result(endpoint, subscription, enqueue(deliv_mod, row, event, opts))

      {:ok, row, :duplicate} ->
        repair(deliv_mod, event, subscription, endpoint, row, opts)

      {:error, reason} ->
        result(endpoint, subscription, :endpoint_error, reason)
    end
  rescue
    reason -> result(endpoint, subscription, :endpoint_error, error_string(reason))
  catch
    # An enqueue seam or storage op that EXITS (a GenServer.call timeout in
    # a queue client) or throws escapes `rescue` — catch it here or the
    # whole fanout dies with later endpoints unprocessed (cross-vendor
    # finding, both peers).
    kind, reason -> result(endpoint, subscription, :endpoint_error, error_string({kind, reason}))
  end

  # The enqueue-repair path: a duplicate row that died at enqueue gets ONE
  # more attempt per re-dispatch, guarded by the claim-then-enqueue CAS.
  # Outcomes: CAS won → reload + enqueue; CAS LOST (another dispatcher
  # already flipped it) → :duplicate, the normal race outcome; CAS ERRORED
  # or reload failed → :endpoint_error, never a mislabeled :duplicate that
  # would hide a state change without an enqueue (cross-vendor finding).
  defp repair(deliv_mod, event, subscription, endpoint, row, opts) do
    if row.status != :enqueue_failed do
      result(endpoint, subscription, :duplicate)
    else
      deliv_mod
      |> claim_for_enqueue_result(row.id)
      |> claimed_row(deliv_mod, row.id)
      |> case do
        {:won, reloaded} ->
          merge_result(endpoint, subscription, enqueue(deliv_mod, reloaded, event, opts))

        {:lost, :race} ->
          result(endpoint, subscription, :duplicate)

        {:lost, reason} ->
          result(endpoint, subscription, :endpoint_error, reason)
      end
    end
  end

  # {:won, row} | {:lost, :race} (another dispatcher flipped it first) |
  # {:lost, reason} (claim errored, or the reload after a won claim failed)
  defp claimed_row(%Ash.BulkResult{status: :success, records: [_]}, deliv_mod, row_id) do
    case reload(deliv_mod, row_id) do
      nil -> {:lost, :claim_lost_on_reload}
      reloaded -> {:won, reloaded}
    end
  end

  defp claimed_row(%Ash.BulkResult{status: :success, records: []}, _deliv_mod, _row_id),
    do: {:lost, :race}

  defp claimed_row(other, _deliv_mod, _row_id), do: {:lost, other}

  # The repair CAS: WHERE-gated on :enqueue_failed, so of N concurrent
  # re-dispatchers exactly one wins the :pending flip (bulk_update's
  # matched-records count is the win signal — the stale loser re-reads and
  # sees the row someone else already claimed).
  defp claim_for_enqueue_result(deliv_mod, row_id) do
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
  end

  defp upsert_row(deliv_mod, event, subscription, endpoint, entity) do
    id = Ash.UUID.generate()

    input = %{
      id: id,
      event_uuid: event.id,
      event_type: event.type,
      payload: event.payload,
      endpoint_id: endpoint.id,
      subscription_id: subscription.id,
      # the EFFECTIVE mode is frozen onto the row at creation — the
      # delivery runtime signs from the row, never re-derives it
      signing_mode: subscription.signing_mode || entity.signing_mode || :standard
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
            :telemetry.execute(
              [:ash_hooks, :dispatch, :enqueue_failed],
              %{},
              %{endpoint_id: row.endpoint_id, event_uuid: row.event_uuid, reason: reason}
            )

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
  catch
    # exits (queue-client GenServer.call timeouts) and throws escape
    # `rescue`; they are enqueue failures like any other (cross-vendor
    # finding, both peers).
    :exit, reason -> {:error, {:exit, reason}}
    :throw, value -> {:error, {:throw, value}}
  end

  # Gated on :pending — the state an enqueue attempt owns: a late failure
  # can never overwrite a row a successful enqueue (or the send runtime)
  # already moved on.
  defp mark_enqueue_failed(deliv_mod, row_id, reason) do
    result =
      with_transient_retry(fn ->
        # the reason arrives ALREADY classified (enqueue_result applied
        # error_string) — re-classifying would mangle the prefixed forms
        deliv_mod
        |> Ash.Query.filter(id == ^row_id and status == :pending)
        |> Ash.bulk_update(:mark_enqueue_failed, %{error: reason},
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
        {matches, error_entries} =
          subscriptions
          |> Enum.filter(&Subscription.matches?(&1, event.type))
          |> resolve_endpoints(endpoint_mod)

        {:ok, matches, error_entries}
      end
    end
  end

  defp read_subscriptions(subs_mod) do
    case with_transient_retry(fn -> Ash.read(subs_mod, authorize?: false) end) do
      {:ok, subscriptions} -> {:ok, subscriptions}
      {:error, error} -> {:error, error}
    end
  end

  # Endpoint resolution distinguishes three outcomes per subscription
  # (cross-vendor finding): an ENABLED endpoint matches; a gone or disabled
  # one is SKIPPED by design (no row, no entry); a READ ERROR after the
  # transient retry is surfaced as a per-endpoint :endpoint_error result —
  # never silently conflated with gone, or a transient blip would drop the
  # event with nothing recorded and nothing re-drivable.
  defp resolve_endpoints(subscriptions, endpoint_mod) do
    subscriptions
    |> Enum.reduce({[], []}, fn subscription, {matches, errors} ->
      subscription
      |> resolve_endpoint(endpoint_mod)
      |> case do
        {:match, endpoint} -> {[{subscription, endpoint} | matches], errors}
        :skip -> {matches, errors}
        {:error, reason} -> {matches, [entry(subscription, reason) | errors]}
      end
    end)
    |> then(fn {matches, errors} -> {Enum.reverse(matches), Enum.reverse(errors)} end)
  end

  defp resolve_endpoint(subscription, endpoint_mod) do
    case with_transient_retry(fn ->
           Ash.get(endpoint_mod, subscription.endpoint_id, authorize?: false)
         end) do
      {:ok, %{status: :enabled} = endpoint} ->
        {:match, endpoint}

      {:ok, _disabled} ->
        :skip

      {:error, %Ash.Error.Invalid{errors: reasons} = error} ->
        if Enum.all?(reasons, &is_struct(&1, Ash.Error.Query.NotFound)) do
          # a GONE endpoint row is a configuration state, not a failure:
          # skip by design (no row, no entry) — same as disabled
          :skip
        else
          {:error, error}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp entry(subscription, error) do
    %{
      endpoint_id: subscription.endpoint_id,
      subscription_id: subscription.id,
      status: :endpoint_error,
      error: error
    }
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

  # A struct is not proof of validation: callers can construct
  # %AshHooks.Event{} directly, bypassing Event.new/1's contract checks —
  # re-validate the fields (a dot-bearing id would otherwise persist and
  # break the signing delimiter invariant downstream; cross-vendor finding).
  defp cast_event(%Event{} = event) do
    with :ok <- check_event_field(event.id, "id", &valid_event_id?/1),
         :ok <- check_event_field(event.type, "type", &valid_event_type?/1),
         :ok <- check_event_field(event.payload, "payload", &(is_binary(&1) and &1 != "")),
         :ok <- check_event_field(event.metadata, "metadata", &is_map/1) do
      {:ok, event}
    end
  end

  defp cast_event(_other),
    do:
      {:error,
       UnknownError.exception(
         error: "event must be an %AshHooks.Event{} — build one with AshHooks.Event.new/1"
       )}

  defp check_event_field(value, name, predicate) do
    if predicate.(value) do
      :ok
    else
      {:error,
       UnknownError.exception(
         error:
           "event #{name} is invalid — build events through AshHooks.Event.new/1 (raw struct construction bypasses its validation)"
       )}
    end
  end

  defp valid_event_id?(id),
    do: is_binary(id) and id != "" and not String.contains?(id, ".") and String.length(id) <= 255

  defp valid_event_type?(type), do: is_binary(type) and type != "" and String.length(type) <= 255

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
    end
  end

  defp error_string({:raised, reason}), do: error_string(reason)

  # exit/throw reasons classify without their contents — a thrown term can
  # carry payload or secret material (the bounded-classification rule).
  defp error_string({:exit, reason}) when is_atom(reason),
    do: ("exit: " <> Atom.to_string(reason)) |> String.slice(0, 255)

  defp error_string({:exit, _reason}), do: "exit: unclassified"

  # contents route through the shared contents-free classifier (the
  # enqueue_failed EVENT and the ledger write share this floor; a thrown
  # or messaged term can carry secret material — cross-vendor finding)
  defp error_string({:throw, value}) when is_binary(value),
    do: "throw: " <> AshHooks.Telemetry.classify_token(value)

  defp error_string({:throw, _value}), do: "throw: unclassified"

  defp error_string(%{__exception__: true} = exception),
    do: AshHooks.Telemetry.classify_token(Exception.message(exception))

  defp error_string(term), do: AshHooks.Telemetry.classify_token(term)

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
    inner = if is_binary(inner), do: inner, else: inspect(inner)
    String.contains?(inner, "Exqlite.Error") and contentiously_busy?(inner)
  end

  defp transient_sqlite_contention?(_other), do: false

  defp contentiously_busy?(inner) do
    down = String.downcase(inner)
    String.contains?(down, "database busy") or String.contains?(down, "database is locked")
  end
end
