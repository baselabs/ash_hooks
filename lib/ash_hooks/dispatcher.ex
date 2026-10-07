defmodule AshHooks.Dispatcher do
  @moduledoc """
  The outbound fanout driver: one event → every matching subscription's
  endpoint → a durable per-endpoint delivery row (+ an enqueue handoff),
  with per-endpoint isolation — the outbound twin of `AshHooks.Ingress`.

      {:ok, event} =
        AshHooks.Event.new(
          type: :order_paid,
          payload: body,
          # Deterministic: derived from the artifact's stable id, so a
          # re-fired producer matches the existing delivery row (the
          # {endpoint_id, event_uuid} dedup) instead of fanning out a
          # duplicate POST per sweep
          id: "msg_order-" <> order.id
        )

      AshHooks.dispatch(Order, :order_paid, event, enqueue: {MyRuntime, :enqueue})

  Each row stores two ownership identifiers. `dispatch_source` binds the row
  to this outbound declaration and endpoint resource. `dispatch_route` binds
  it to the enqueue callback. A duplicate with a different source or route
  fails explicitly; it cannot silently adopt another declaration or queue.
  Named callbacks and external captures normalize to one route. Anonymous
  callbacks need a stable `:enqueue_key` for periodic recovery. Without one,
  dispatch can enqueue immediately, but recovery reports `:unresolved_route`.

  The runtime contract:

    * every matching enabled endpoint gets a delivery row unique on
      `{endpoint_id, event_uuid}`. The worker's queue identity adds the
      complete delivery key, resource modules, source, route, and tenant;
    * the row persists before enqueue — payload bytes included —
      so a later runtime can sign and send from the ledger of record
      alone;
    * one endpoint's enqueue failure or raise records `:enqueue_failed`
      on its row and never stops the others (the fanout-isolation
      guarantee);
    * re-dispatching an `:enqueue_failed` event conditionally moves that row
      back to `:pending`; only the dispatcher that wins the update calls the
      enqueuer. Scheduled reconciliation uses a separate enqueue token and
      30-second lease, so a crashed claimant becomes recoverable without
      borrowing the send lease or retry schedule;
    * with no `:enqueue` configured the rows persist `:pending` and the
      results say `:deferred` — the durable ledger IS the source of
      truth; the delivery runtime (`AshHooks.Delivery`) drives pending
      rows from there.

  Global failures (unknown outbound declaration, an invalid event or enqueue
  route, missing DSL module options, an unreadable subscription set, or
  divergent effective signing modes for one endpoint) return
  `{:error, reason}` before any row is written. Subscriptions are read through the
  consumer's primary read action and endpoints through their resource's
  `get` — both unauthorized, the signature of the inbound machine: the
  dispatch call is the trust boundary for writes, read surfaces stay
  governed by consumer policies (ADR-0005).
  """

  require Ash.Expr
  require Ash.Query

  alias AshHooks.Errors.Unknown.UnknownError
  alias AshHooks.{Event, Info, OutboundBinding, PrimaryKey, Subscription, Tenancy}
  alias Spark.Dsl.Extension

  @typedoc """
  The dispatch result contract (public since 1.2.0): one map per endpoint.
  """
  @type dispatch_result :: %{
          endpoint_id: term(),
          subscription_id: term(),
          status:
            :created
            | :duplicate
            | :deferred
            | :enqueue_failed
            | :mark_failed
            | :endpoint_error
            | :reconciled,
          error: term()
        }

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
    * `:enqueue_key` — stable, nonempty binary (up to 512 bytes) or atom
      identity for an anonymous enqueue callback. Supply it when periodic
      recovery must reconstruct that route.
    * `:tenant` — the dispatch tenant. On multitenant resources (the
      tenancy contract: every touched resource declares attribute
      multitenancy over the same attribute) this scopes the fanout, the
      endpoint resolution, and every ledger write to the tenant; omitting
      it there is `{:error, :tenant_required}` before any data access.
      On single-tenant resources the option is inert.
  """
  @spec dispatch(module(), atom(), Event.t() | term(), keyword()) ::
          {:ok, [dispatch_result()]} | {:error, term()}
  def dispatch(resource, name, event, opts \\ []) do
    with {:ok, entity} <- fetch_outbound(resource, name),
         {:ok, event} <- cast_event(event),
         :ok <- check_type_alignment(name, event),
         {:ok, subs_mod} <- resolve_module(entity, :subscriptions),
         {:ok, deliv_mod} <- resolve_module(entity, :deliveries),
         {:ok, endpoint_mod} <- resolve_endpoint_resource(subs_mod),
         {:ok, route} <- OutboundBinding.route(opts[:enqueue], opts),
         {:ok, tenant} <- Tenancy.resolve([subs_mod, endpoint_mod, deliv_mod], opts[:tenant]),
         {:ok, matches, error_entries} <-
           match_subscriptions(subs_mod, endpoint_mod, event, tenant),
         :ok <- check_conflicts(matches, entity) do
      binding = %{
        source: OutboundBinding.source(resource, name, endpoint_mod),
        route: route
      }

      {:ok,
       error_entries ++
         (matches
          |> dedupe_by_endpoint()
          |> Enum.map(&dispatch_one(deliv_mod, event, &1, opts, entity, binding, tenant)))}
    end
  end

  # The declaration resolves configuration (resource modules, signing-mode
  # default); the event's type routes subscriptions. Letting the two
  # diverge routes one declaration's resources at another type's
  # subscribers — fail closed on the mismatch.
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

  defp dispatch_one(deliv_mod, event, {subscription, endpoint}, opts, entity, binding, tenant) do
    case upsert_row(deliv_mod, event, subscription, endpoint, entity, binding, tenant) do
      {:ok, row, disposition} ->
        case validate_binding(row, binding) do
          :ok ->
            dispatch_bound_result(
              disposition,
              deliv_mod,
              row,
              event,
              subscription,
              endpoint,
              opts,
              tenant
            )

          {:error, reason} ->
            result(endpoint, subscription, :endpoint_error, reason)
        end

      {:error, reason} ->
        result(endpoint, subscription, :endpoint_error, reason)
    end
  rescue
    reason -> result(endpoint, subscription, :endpoint_error, error_string(reason))
  catch
    # An enqueue seam or storage op that EXITS (a GenServer.call timeout in
    # a queue client) or throws escapes `rescue` — catch it here or the
    # whole fanout dies with later endpoints unprocessed.
    kind, reason -> result(endpoint, subscription, :endpoint_error, error_string({kind, reason}))
  end

  defp dispatch_bound_result(
         :created,
         deliv_mod,
         row,
         event,
         subscription,
         endpoint,
         opts,
         tenant
       ) do
    merge_result(endpoint, subscription, enqueue(deliv_mod, row, event, opts, tenant))
  end

  defp dispatch_bound_result(
         :duplicate,
         deliv_mod,
         row,
         event,
         subscription,
         endpoint,
         opts,
         tenant
       ) do
    repair(deliv_mod, event, subscription, endpoint, row, opts, tenant)
  end

  # The enqueue-repair path: a duplicate row that died at enqueue gets ONE
  # more attempt per re-dispatch, guarded by the claim-then-enqueue CAS.
  # Outcomes: CAS won → reload + enqueue; CAS LOST (another dispatcher
  # already flipped it) → :duplicate, the normal race outcome; CAS ERRORED
  # or reload failed → :endpoint_error, never a mislabeled :duplicate that
  # would hide a state change without an enqueue.
  defp repair(deliv_mod, event, subscription, endpoint, row, opts, tenant) do
    if row.status != :enqueue_failed do
      result(endpoint, subscription, :duplicate)
    else
      deliv_mod
      |> claim_for_enqueue_result(row, tenant)
      |> claimed_row(deliv_mod, row, tenant)
      |> case do
        {:won, reloaded} ->
          merge_result(endpoint, subscription, enqueue(deliv_mod, reloaded, event, opts, tenant))

        {:lost, :race} ->
          result(endpoint, subscription, :duplicate)

        {:lost, reason} ->
          result(endpoint, subscription, :endpoint_error, reason)
      end
    end
  end

  # {:won, row} | {:lost, :race} (another dispatcher flipped it first) |
  # {:lost, reason} (claim errored, or the reload after a won claim failed)
  defp claimed_row(%Ash.BulkResult{status: :success, records: [_]}, deliv_mod, row, tenant) do
    case reload(deliv_mod, row, tenant) do
      nil -> {:lost, :claim_lost_on_reload}
      reloaded -> {:won, reloaded}
    end
  end

  defp claimed_row(%Ash.BulkResult{status: :success, records: []}, _deliv_mod, _row, _tenant),
    do: {:lost, :race}

  defp claimed_row(other, _deliv_mod, _row_id, _tenant), do: {:lost, other}

  # The repair CAS: WHERE-gated on :enqueue_failed, so of N concurrent
  # re-dispatchers exactly one wins the :pending flip (bulk_update's
  # matched-records count is the win signal — the stale loser re-reads and
  # sees the row someone else already claimed).
  defp claim_for_enqueue_result(deliv_mod, row, tenant) do
    with_transient_retry(fn ->
      deliv_mod
      |> Ash.Query.do_filter(PrimaryKey.filter(row))
      |> Ash.Query.filter(status == :enqueue_failed)
      |> Ash.bulk_update(:requeue, %{},
        authorize?: false,
        return_records?: true,
        return_errors?: true,
        strategy: [:atomic],
        tenant: tenant
      )
    end)
  end

  defp upsert_row(deliv_mod, event, subscription, endpoint, entity, binding, tenant) do
    input =
      %{
        event_uuid: event.id,
        event_type: event.type,
        endpoint_id: PrimaryKey.scalar!(endpoint),
        subscription_id: PrimaryKey.scalar!(subscription),
        # the EFFECTIVE mode is frozen onto the row at creation — the
        # delivery runtime signs from the row, never re-derives it
        signing_mode: subscription.signing_mode || entity.signing_mode || :standard,
        dispatch_source: binding.source,
        dispatch_route: binding.route
      }
      # the exact-bytes column's name is consumer-configurable (H1)
      |> Map.put(AshHooks.Info.payload_attribute(deliv_mod), event.payload)

    if Info.writable_id?(deliv_mod) and Ash.Resource.Info.primary_key(deliv_mod) == [:id] do
      dispatch_with_supplied_id(deliv_mod, input, tenant)
    else
      upsert_with_pre_read(deliv_mod, input, tenant)
    end
  end

  defp dispatch_with_supplied_id(deliv_mod, input, tenant) do
    id = Ash.UUID.generate()

    case with_transient_retry(fn ->
           Ash.create(deliv_mod, Map.put(input, :id, id),
             action: :dispatch,
             authorize?: false,
             tenant: tenant
           )
         end) do
      {:ok, row} -> {:ok, row, if(row.id == id, do: :created, else: :duplicate)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp upsert_with_pre_read(deliv_mod, input, tenant) do
    case fetch_delivery(deliv_mod, input.endpoint_id, input.event_uuid, tenant) do
      {:ok, row} -> {:ok, row, :duplicate}
      :missing -> create_pre_read_row(deliv_mod, input, tenant)
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_pre_read_row(deliv_mod, input, tenant) do
    with_transient_retry(fn ->
      Ash.create(deliv_mod, input, action: :dispatch, authorize?: false, tenant: tenant)
    end)
    |> case do
      {:ok, row} -> {:ok, row, :created}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_delivery(deliv_mod, endpoint_id, event_uuid, tenant) do
    result =
      with_transient_retry(fn ->
        deliv_mod
        |> Ash.Query.filter(endpoint_id == ^endpoint_id and event_uuid == ^event_uuid)
        |> Ash.read_one(authorize?: false, tenant: tenant)
      end)

    case result do
      {:ok, nil} -> :missing
      {:ok, row} -> {:ok, row}
      {:error, reason} -> {:error, reason}
    end
  end

  defp enqueue(deliv_mod, row, event, opts, tenant) do
    case enqueue_result(opts[:enqueue], row, event) do
      :ok ->
        %{status: :created, error: nil}

      :deferred ->
        %{status: :deferred, error: nil}

      {:error, reason} ->
        case mark_enqueue_failed(deliv_mod, row, reason, tenant) do
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
      endpoint_id: PrimaryKey.scalar!(endpoint),
      subscription_id: PrimaryKey.scalar!(subscription),
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

  defp safe_enqueuer(enqueuer, row, event) do
    enqueuer.(row, event)
  rescue
    reason -> {:error, {:raised, reason}}
  catch
    # exits (queue-client GenServer.call timeouts) and throws escape
    # `rescue`; they are enqueue failures like any other.
    :exit, reason -> {:error, {:exit, reason}}
    :throw, value -> {:error, {:throw, value}}
  end

  # Gated on :pending — the state an enqueue attempt owns: a late failure
  # can never overwrite a row a successful enqueue (or the send runtime)
  # already moved on.
  defp mark_enqueue_failed(deliv_mod, row, reason, tenant) do
    result =
      with_transient_retry(fn ->
        # the reason arrives ALREADY classified (enqueue_result applied
        # error_string) — re-classifying would mangle the prefixed forms
        deliv_mod
        |> Ash.Query.do_filter(PrimaryKey.filter(row))
        |> Ash.Query.filter(status == :pending)
        |> Ash.bulk_update(:mark_enqueue_failed, %{error: reason},
          authorize?: false,
          return_records?: true,
          return_errors?: true,
          strategy: [:atomic],
          tenant: tenant
        )
      end)

    case bulk_one(result, :stale_row) do
      {:ok, _row} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp reload(deliv_mod, row, tenant) do
    case with_transient_retry(fn ->
           deliv_mod
           |> Ash.Query.do_filter(PrimaryKey.filter(row))
           |> Ash.read_one(authorize?: false, tenant: tenant)
         end) do
      {:ok, row} when not is_nil(row) -> row
      _missing_or_error -> nil
    end
  end

  defp validate_binding(row, binding) do
    cond do
      row.dispatch_source != binding.source -> {:error, :dispatch_source_conflict}
      row.dispatch_route != binding.route -> {:error, :dispatch_route_conflict}
      true -> :ok
    end
  end

  # ────────────────────────── match + validate ──────────────────────────

  # The pre-flight needs the endpoint module too (the tenancy contract
  # spans every touched resource), so resolution moved out of the match —
  # an undeclared endpoint_resource is a global failure before data access.
  defp resolve_endpoint_resource(subs_mod) do
    case Extension.get_opt(subs_mod, [:subscription], :endpoint_resource, nil) do
      nil ->
        {:error,
         UnknownError.exception(
           error:
             "#{inspect(subs_mod)} declares no subscription.endpoint_resource — the dispatcher cannot resolve endpoints"
         )}

      module when is_atom(module) ->
        {:ok, module}
    end
  end

  defp match_subscriptions(subs_mod, endpoint_mod, event, tenant) do
    with {:ok, subscriptions} <- read_subscriptions(subs_mod, tenant) do
      {matches, error_entries} =
        subscriptions
        |> Enum.filter(&Subscription.matches?(&1, event.type))
        |> resolve_endpoints(endpoint_mod, tenant)

      {:ok, matches, error_entries}
    end
  end

  defp read_subscriptions(subs_mod, tenant) do
    case with_transient_retry(fn ->
           Ash.read(subs_mod, authorize?: false, tenant: tenant)
         end) do
      {:ok, subscriptions} -> collect_pages(subscriptions, [])
      {:error, error} -> {:error, error}
    end
  end

  defp collect_pages(%{results: results, more?: true} = page, acc) do
    with {:ok, next} <- with_transient_retry(fn -> Ash.page(page, :next) end) do
      collect_pages(next, [results | acc])
    end
  end

  defp collect_pages(%{results: results}, acc),
    do: {:ok, acc |> Enum.reverse() |> Enum.concat() |> Kernel.++(results)}

  defp collect_pages(subscriptions, []) when is_list(subscriptions), do: {:ok, subscriptions}

  # Endpoint resolution distinguishes three outcomes per subscription
  # : an ENABLED endpoint matches; a gone or disabled
  # one is SKIPPED by design (no row, no entry); a READ ERROR after the
  # transient retry is surfaced as a per-endpoint :endpoint_error result —
  # never silently conflated with gone, or a transient blip would drop the
  # event with nothing recorded and nothing re-drivable.
  defp resolve_endpoints(subscriptions, endpoint_mod, tenant) do
    subscriptions
    |> Enum.reduce({[], []}, fn subscription, {matches, errors} ->
      subscription
      |> resolve_endpoint(endpoint_mod, tenant)
      |> case do
        {:match, endpoint} -> {[{subscription, endpoint} | matches], errors}
        :skip -> {matches, errors}
        {:error, reason} -> {matches, [entry(subscription, reason) | errors]}
      end
    end)
    |> then(fn {matches, errors} -> {Enum.reverse(matches), Enum.reverse(errors)} end)
  end

  # A cross-tenant endpoint_id resolves NotFound under the dispatch's
  # tenant (the tenant filter rides the get) and classifies as the SAME
  # misconfiguration skip a gone endpoint gets — tenant-enforced, no new
  # outcome shape.
  defp resolve_endpoint(subscription, endpoint_mod, tenant) do
    case with_transient_retry(fn ->
           Ash.get(endpoint_mod, subscription.endpoint_id, authorize?: false, tenant: tenant)
         end) do
      # the ONE enabled-check (H4): the injected status attribute or the
      # consumer-mapped switch — exactly one attribute decides
      {:ok, endpoint} ->
        if AshHooks.Endpoint.enabled?(endpoint), do: {:match, endpoint}, else: :skip

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
      subscription_id: PrimaryKey.scalar!(subscription),
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
      {subscription.endpoint_id, PrimaryKey.scalar!(subscription)}
    end)
    |> Enum.uniq_by(fn {subscription, _endpoint} -> subscription.endpoint_id end)
  end

  # ────────────────────────── orphan-pending reconciliation ──────────────────────────

  # 5 minutes: far beyond any enqueue window, so a live enqueue cannot be
  # raced by a reconciler with the default cutoff (the ordering caveat the
  # tenancy design documents — a cutoff overlapping enqueue latency would
  # claim rows whose enqueue is merely slow; the CAS discipline itself is
  # the residual protection there).
  @reconcile_default_cutoff_seconds 300
  @enqueue_lease_seconds 30

  @doc """
  Recovers source-owned delivery rows: stale `:pending`, `:enqueue_failed`,
  due `:failed_retryable`, expired `:sending`, and `:disable_pending`.
  Future retries and live send leases are ineligible.

  Each row is claimed with a separate enqueue token and a 30-second lease in the
  same atomic update that checks its state and due time. Successful durable
  admission releases the token and PARKS the enqueue lease for one 30-second
  horizon (the row stays unclaimable while concurrent sweeps from the same
  recovery window are in flight — a sweep inside that horizon sees the row as a
  contended `:duplicate`); the row's delivery state, attempts, retry time, send
  lease, and `last_error` diagnostic are preserved. A failed enqueue releases
  the claim fully and records its bounded error. A crash leaves a reclaimable lease. The enqueue
  seam must remain idempotent because an external effect can occur before a
  crashed claimant clears its lease.

  Reconciliation validates the stored declaration source and route. A
  deferred unbound route may bind once to a named callback or to an anonymous
  callback carrying the same stable `:enqueue_key`. An unkeyed anonymous route
  returns `:unresolved_route` and is never rebound implicitly.

  Options: `:older_than` (staleness cutoff; default now minus 5 minutes),
  `:tenant` (the pre-flight applies), `:enqueue`, and `:enqueue_key`. The seam
  receives the event reconstructed from the row, never nil. The resource
  must carry `inserted_at` (the retention hooks' requirement).

  Keep the cutoff beyond normal enqueue latency. The default cutoff moves
  with the clock; periodic recovery is a host scheduling obligation.
  """
  @spec reconcile_pending(module(), atom(), keyword()) ::
          {:ok, [dispatch_result()]} | {:error, term()}
  def reconcile_pending(resource, name, opts \\ []) do
    with {:ok, entity} <- fetch_outbound(resource, name),
         {:ok, deliv_mod} <- resolve_module(entity, :deliveries),
         {:ok, subs_mod} <- resolve_module(entity, :subscriptions),
         {:ok, endpoint_mod} <- resolve_endpoint_resource(subs_mod),
         {:ok, route} <- OutboundBinding.route(opts[:enqueue], opts),
         {:ok, tenant} <-
           Tenancy.resolve([subs_mod, endpoint_mod, deliv_mod], opts[:tenant]),
         :ok <- require_timestamps(deliv_mod),
         recovery_cutoff <- cutoff(opts),
         {:ok, candidates} <-
           recovery_candidates(
             deliv_mod,
             OutboundBinding.source(resource, name, endpoint_mod),
             recovery_cutoff,
             tenant
           ) do
      {:ok,
       Enum.map(candidates, fn row ->
         reconcile_one(deliv_mod, row, route, opts, recovery_cutoff, tenant)
       end)}
    end
  end

  defp cutoff(opts) do
    DateTime.truncate(opts[:older_than] || default_cutoff(), :microsecond)
  end

  defp default_cutoff do
    DateTime.add(DateTime.utc_now(), -@reconcile_default_cutoff_seconds, :second)
  end

  defp require_timestamps(deliv_mod) do
    if Ash.Resource.Info.attribute(deliv_mod, :inserted_at) do
      :ok
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

  defp recovery_candidates(deliv_mod, source, cutoff, tenant) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    result =
      with_transient_retry(fn ->
        deliv_mod
        |> Ash.Query.filter(dispatch_source == ^source)
        |> recovery_candidate_filter(cutoff, now)
        |> Ash.read(authorize?: false, tenant: tenant)
      end)

    case result do
      {:ok, rows} -> collect_pages(rows, [])
      {:error, error} -> {:error, error}
    end
  end

  defp recovery_candidate_filter(query, cutoff, now) do
    filters = [
      pending_recovery_filter(cutoff),
      Ash.Expr.expr(status in [:enqueue_failed, :disable_pending]),
      retry_recovery_filter(now),
      sending_recovery_filter(now)
    ]

    filter = Enum.reduce(filters, fn expression, acc -> Ash.Expr.expr(^acc or ^expression) end)
    Ash.Query.do_filter(query, filter)
  end

  defp pending_recovery_filter(cutoff),
    do: Ash.Expr.expr(status == :pending and inserted_at < ^cutoff)

  defp retry_recovery_filter(now),
    do:
      Ash.Expr.expr(
        status == :failed_retryable and
          (is_nil(next_attempt_at) or next_attempt_at <= ^now)
      )

  defp sending_recovery_filter(now),
    do:
      Ash.Expr.expr(
        status == :sending and
          (is_nil(send_lease_expires_at) or send_lease_expires_at <= ^now)
      )

  defp reconcile_one(deliv_mod, row, route, opts, cutoff, tenant) do
    with {:ok, row} <- bind_or_validate_route(deliv_mod, row, route, tenant),
         {:ok, claimed} <- claim_enqueue(deliv_mod, row, cutoff, tenant) do
      reconcile_claimed(deliv_mod, claimed, opts, tenant)
    else
      {:error, :enqueue_contended} -> reconcile_result(row, :duplicate, :enqueue_contended)
      {:error, reason} -> reconcile_result(row, :enqueue_failed, reason)
    end
  end

  defp reconcile_claimed(deliv_mod, claimed, opts, tenant) do
    case row_event(claimed) do
      {:ok, event} ->
        reconcile_enqueue_result(
          deliv_mod,
          claimed,
          enqueue_result(opts[:enqueue], claimed, event),
          tenant
        )

      {:error, reason} ->
        release_reconcile_claim(
          deliv_mod,
          claimed,
          error_string(reason),
          :enqueue_failed,
          reason,
          tenant
        )
    end
  end

  defp reconcile_enqueue_result(deliv_mod, claimed, result, tenant) do
    case result do
      :ok ->
        # A successful release PRESERVES the row's failure diagnostic by replaying
        # its current value — re-admission is a transport event, not a delivery
        # outcome; only the {:error, _} branch (a fresh enqueue failure) writes a
        # new story. (The sirtify-routed last_error-wipe finding.)
        release_reconcile_claim(deliv_mod, claimed, claimed.last_error, :reconciled, nil, tenant)

      {:error, reason} ->
        release_reconcile_claim(
          deliv_mod,
          claimed,
          error_string(reason),
          :enqueue_failed,
          reason,
          tenant
        )
    end
  end

  defp release_reconcile_claim(deliv_mod, claimed, error, status, reason, tenant) do
    # The park decision is the explicit enqueue outcome (:reconciled admitted
    # durably) — never the error string, which on success carries the
    # PRESERVED diagnostic.
    enqueue_succeeded? = match?(:reconciled, status)

    case release_enqueue(deliv_mod, claimed, error, tenant, enqueue_succeeded?) do
      :ok -> reconcile_result(claimed, status, reason)
      {:error, release_reason} -> reconcile_result(claimed, :endpoint_error, release_reason)
    end
  end

  defp bind_or_validate_route(_deliv_mod, _row, route, _tenant)
       when route in ["v1:route:unbound", "v1:route:anonymous:unkeyed"],
       do: {:error, :unresolved_route}

  defp bind_or_validate_route(deliv_mod, row, route, tenant) do
    cond do
      row.dispatch_route == route ->
        {:ok, row}

      row.dispatch_route == OutboundBinding.unbound_route() ->
        result =
          deliv_mod
          |> Ash.Query.do_filter(PrimaryKey.filter(row))
          |> Ash.Query.filter(
            dispatch_source == ^row.dispatch_source and
              dispatch_route == ^OutboundBinding.unbound_route()
          )
          |> Ash.bulk_update(:bind_dispatch_route, %{dispatch_route: route},
            authorize?: false,
            return_records?: true,
            return_errors?: true,
            strategy: [:atomic],
            tenant: tenant
          )

        bulk_one(result, :dispatch_route_conflict)

      row.dispatch_route == OutboundBinding.unkeyed_route() ->
        {:error, :unresolved_route}

      true ->
        {:error, :dispatch_route_conflict}
    end
  end

  defp claim_enqueue(deliv_mod, row, cutoff, tenant) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    token = Ash.UUID.generate()
    lease = DateTime.add(now, @enqueue_lease_seconds, :second)

    result =
      deliv_mod
      |> Ash.Query.do_filter(PrimaryKey.filter(row))
      |> Ash.Query.filter(
        dispatch_source == ^row.dispatch_source and dispatch_route == ^row.dispatch_route and
          (is_nil(enqueue_lease_expires_at) or enqueue_lease_expires_at <= ^now)
      )
      |> recovery_state_filter(row.status, cutoff, now)
      |> Ash.bulk_update(
        :claim_enqueue,
        %{enqueue_token: token, enqueue_lease_expires_at: lease},
        authorize?: false,
        return_records?: true,
        return_errors?: true,
        strategy: [:atomic],
        tenant: tenant
      )

    bulk_one(result, :enqueue_contended)
  end

  defp recovery_state_filter(query, :pending, cutoff, _now),
    do: Ash.Query.filter(query, status == :pending and inserted_at < ^cutoff)

  defp recovery_state_filter(query, :enqueue_failed, _cutoff, _now),
    do: Ash.Query.filter(query, status == :enqueue_failed)

  defp recovery_state_filter(query, :failed_retryable, _cutoff, now),
    do:
      Ash.Query.filter(
        query,
        status == :failed_retryable and
          (is_nil(next_attempt_at) or next_attempt_at <= ^now)
      )

  defp recovery_state_filter(query, :sending, _cutoff, now),
    do:
      Ash.Query.filter(
        query,
        status == :sending and
          (is_nil(send_lease_expires_at) or send_lease_expires_at <= ^now)
      )

  defp recovery_state_filter(query, :disable_pending, _cutoff, _now),
    do: Ash.Query.filter(query, status == :disable_pending)

  defp release_enqueue(deliv_mod, row, error, tenant, enqueue_succeeded?) do
    # A SUCCESSFUL enqueue parks the lease for one horizon: the row stays
    # unclaimable while CONCURRENT sweeps from the same recovery window are
    # still in flight, so admission is exactly-once per recovery window at the
    # seam. The park decision is the explicit enqueue outcome — never the
    # error string, which on success carries the PRESERVED diagnostic. A
    # failed enqueue releases fully (the next sweep must re-claim it).
    parked =
      if enqueue_succeeded? do
        DateTime.add(
          DateTime.utc_now() |> DateTime.truncate(:microsecond),
          @enqueue_lease_seconds,
          :second
        )
      else
        nil
      end

    result =
      deliv_mod
      |> Ash.Query.do_filter(PrimaryKey.filter(row))
      |> Ash.Query.filter(
        dispatch_source == ^row.dispatch_source and enqueue_token == ^row.enqueue_token
      )
      |> Ash.bulk_update(:release_enqueue, %{error: error, enqueue_lease_expires_at: parked},
        authorize?: false,
        return_records?: true,
        return_errors?: true,
        strategy: [:atomic],
        tenant: tenant
      )

    case bulk_one(result, :stale_enqueue_claim) do
      {:ok, _row} ->
        :ok

      {:error, :stale_enqueue_claim} ->
        # A terminal/retryable outcome between claim and release CLEARS the
        # enqueue claim in the same statement, so the release matching zero
        # rows here means the worker already finished the row — benign
        # completion, never a release failure. Only a row that is STILL
        # live-claimed is a genuine stale claim.
        classify_stale_claim(deliv_mod, row, tenant)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp classify_stale_claim(deliv_mod, row, tenant) do
    case reload(deliv_mod, row, tenant) do
      # The claim was released by an outcome (terminal, retryable, or the stored
      # 410 obligation) — benign completion. A live token is genuine contention;
      # a row that vanished or could not be reloaded is its own (distinguishable)
      # failure, never silently one of the other two.
      %{enqueue_token: nil} -> :ok
      %{} -> {:error, :stale_enqueue_claim}
      nil -> {:error, :enqueue_reload_failed}
    end
  end

  defp bulk_one(%Ash.BulkResult{status: :success, records: [row]}, _empty), do: {:ok, row}
  defp bulk_one(%Ash.BulkResult{status: :success, records: []}, empty), do: {:error, empty}

  defp bulk_one(%Ash.BulkResult{} = result, _empty),
    do: {:error, List.first(result.errors || []) || result}

  # the enqueue seam takes (delivery, event) — reconstruction from the
  # row instead of a nil, so a seam matching %Event{} or reading event
  # fields works during reconciliation. The ledger row persists id, type, and
  # payload ONLY: the reconstructed event carries an empty metadata map —
  # a seam that needs the ORIGINAL dispatch-time metadata must tolerate
  # that (the row never stored it).
  defp row_event(row) do
    Event.new(
      type: row.event_type,
      payload: Map.get(row, AshHooks.Info.payload_attribute(row.__struct__)),
      id: row.event_uuid
    )
  end

  defp reconcile_result(row, status, error) do
    %{
      endpoint_id: row.endpoint_id,
      subscription_id: row.subscription_id,
      status: status,
      error: error
    }
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
  # break the signing delimiter invariant downstream).
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

  # Byte bounds, not String.length (graphemes): the injected event_uuid /
  # event_type attributes carry max_length: 255, which under Ash 3.33's
  # :codepoints mode counts codepoints — a grapheme-counted guard passed
  # 255 combining-grapheme values the ledger then rejected, failing every
  # endpoint's :dispatch create. Bytes bound codepoints and graphemes
  # alike; the inbound side already bounds bytes (ingress external ids).
  defp valid_event_id?(id), do: Event.valid_id?(id)

  defp valid_event_type?(type), do: is_binary(type) and type != "" and byte_size(type) <= 255

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
  # Byte cap so the 255 constraint holds in any counting mode.
  defp error_string({:exit, reason}) when is_atom(reason),
    do:
      ("exit: " <> AshHooks.Telemetry.classify_token(reason))
      |> AshHooks.BoundedText.cap(255)

  defp error_string({:exit, _reason}), do: "exit: unclassified"

  # contents route through the shared contents-free classifier (the
  # enqueue_failed EVENT and the ledger write share this floor; a thrown
  # or messaged term can carry secret material).
  # The cap covers the 7-byte prefix too: classify_token alone can return
  # 255, and "throw: " <> 255 violated last_error's max_length in every
  # counting mode, failing the enqueue-failure ledger write itself.
  defp error_string({:throw, value}) when is_binary(value),
    do: AshHooks.BoundedText.cap("throw: " <> AshHooks.Telemetry.classify_token(value), 255)

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
