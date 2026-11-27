defmodule AshHooks.OutboundEvent do
  @moduledoc """
  Turns the consumer's resource into the outbound EVENT log: exactly one
  row per dispatched event (its id, type, declared payload version, time,
  and exact payload bytes), recorded whether or not any endpoint was
  enabled (or existed), with its own retention.


  <!-- not-run: These fragments require a host event resource and the enclosing producer declaration. -->

      use Ash.Resource,
        data_layer: AshPostgres.DataLayer,
        extensions: [AshHooks.OutboundEvent]

      # and on the emitting resource's declaration:
      outbound :order_paid do
        events MyApp.OutboundEvent
      end

  The dispatcher writes through the injected `:record` machine action (an
  idempotent no-touch upsert on the event id); a log write failure never
  stops the fanout; it surfaces as `[:ash_hooks, :event, :record_failed]`
  telemetry. The delivery ledger remains the delivery contract; this log
  is the source of record for what was EMITTED, the answer behind "what
  did we send, ever, that endpoint X never received?".

  Rows carry the exact payload bytes you dispatched; govern read access
  with your own policies. The resource needs `timestamps()` (the event's
  time is `inserted_at`), and your migration carries the table plus the
  `unique_event` index on `[:event_uuid]`.

  Enable `outbound_event do replay_context(:on) end` to record context
  for filtered replay and payload-version pins. Migrate the event table to
  add the nullable `:replay_context` map column before enabling it. The
  default is `:off`. The column stores only metadata keys listed in the
  declaration's subscription resource `filter_attributes`, the list of
  keys covered at capture, and payload-version information. Metadata
  uses the outbox's portable JSON limits (32 levels and 1 MiB). If it
  cannot be captured within those limits, the event is still logged.

  Policy obligation: protect the injected `:record` create and `:prune`
  destroy actions wherever your domain exposes the resource; the
  runtime's internal calls bypass authorization by design.
  """

  require Ash.Query

  alias AshHooks.{Catalog, Delivery, Dispatcher, Event, Keyset, PrimaryKey, Tenancy}
  alias AshHooks.Errors.Unknown.UnknownError
  alias AshHooks.OutboundOutbox.Metadata
  alias Spark.Dsl.Extension

  # ────────────────────────── queries + retention ──────────────────────────

  @doc """
  Lists logged events by filter with keyset pagination (newest first).

  Options: `:event_type`, `:event_uuid`, `:from` / `:to` (`DateTime`
  bounds on `inserted_at`, inclusive), `:limit` (default 50, max 500),
  `:after` (the previous page's cursor), and `:tenant` (the tenancy
  pre-flight applies). Returns `{:ok, %{records:, next_cursor:}}`.
  """
  @spec list(module(), keyword()) ::
          {:ok, %{records: [struct()], next_cursor: binary() | nil}} | {:error, term()}
  def list(resource, opts \\ []) do
    with {:ok, tenant} <- Tenancy.resolve([resource], opts[:tenant]),
         :ok <- require_timestamps(resource) do
      Keyset.read_page(resource, opts, :inserted_at, &list_filters(&1, opts), tenant)
    end
  end

  defp require_timestamps(resource) do
    if Ash.Resource.Info.attribute(resource, :inserted_at) do
      :ok
    else
      {:error,
       UnknownError.exception(
         error:
           inspect(resource) <>
             " has no :inserted_at; add `timestamps()` to its attributes " <>
             "(and the columns to its migration) to use the event log"
       )}
    end
  end

  defp list_filters(query, opts) do
    query
    |> optional_eq(:event_type, opts[:event_type])
    |> optional_eq(:event_uuid, opts[:event_uuid])
    |> time_range(opts[:from], opts[:to])
  end

  defp optional_eq(query, _field, nil), do: query

  defp optional_eq(query, field, value) do
    require Ash.Expr
    ref = Ash.Expr.ref(field)
    expression = Ash.Expr.expr(^ref == ^value)
    Ash.Query.filter(query, ^expression)
  end

  defp time_range(query, nil, nil), do: query

  defp time_range(query, from, to) do
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

  @doc """
  The event log's own retention hook: deletes logged events older than
  `older_than`, by `inserted_at`, in batches (`:batch_size`, default 500).
  Returns `{:ok, deleted_count}`.
  """
  @spec prune(module(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def prune(resource, opts) do
    older_than = DateTime.truncate(Keyword.fetch!(opts, :older_than), :microsecond)

    with {:ok, tenant} <- Tenancy.resolve([resource], opts[:tenant]),
         :ok <- require_timestamps(resource) do
      prune_batches(resource, older_than, tenant, Keyword.get(opts, :batch_size, 500), 0)
    end
  end

  defp prune_batches(resource, older_than, tenant, batch_size, total)
       when is_integer(batch_size) and batch_size > 0 and batch_size <= 5_000 do
    result =
      AshHooks.Phase.bulk(
        resource
        |> Ash.Query.filter(inserted_at < ^older_than)
        |> Ash.Query.limit(batch_size),
        tenant,
        &Ash.bulk_destroy(&1, :prune, %{},
          authorize?: false,
          return_records?: true,
          return_errors?: true,
          strategy: [:atomic],
          tenant: tenant
        )
      )

    case result do
      %Ash.BulkResult{status: :success, records: []} ->
        {:ok, total}

      %Ash.BulkResult{status: :success, records: rows} when length(rows) < batch_size ->
        {:ok, total + length(rows)}

      %Ash.BulkResult{status: :success, records: rows} ->
        prune_batches(resource, older_than, tenant, batch_size, total + length(rows))

      %Ash.BulkResult{} = result ->
        {:error, List.first(result.errors || []) || result}
    end
  end

  defp prune_batches(_resource, _older_than, _tenant, _batch_size, _total),
    do: {:error, :invalid_batch_size}

  # ────────────────────────── replay ──────────────────────────

  @doc false
  def capture_context(subscriptions, event) do
    keys =
      subscriptions
      |> Extension.get_opt([:subscription], :filter_attributes, [])
      |> Enum.map(&Atom.to_string/1)
      |> Enum.uniq()

    projected = Map.take(event.metadata, keys)

    with {:ok, encoded} <- Metadata.encode(projected),
         {:ok, _bounded_keys} <- Metadata.encode(%{"keys" => keys}) do
      %{
        metadata_json: encoded,
        captured_keys: keys,
        complete: projected === event.metadata,
        event_version: event.version
      }
    else
      :error -> %{complete: false, event_version: event.version}
    end
  end

  @doc """
  Replays selected logged events to one endpoint, preserving event IDs.

  Options: required `:deliveries`, `:endpoints`, `:requested_by`, and
  `declaration: {Emitter, :event_name}` identifying the outbound declaration.
  The declaration must use the supplied event log, deliveries, and endpoints.
  Optional: `:enqueue`, `:enqueue_key`, `:tenant`, `:event_uuid`, `:event_type`,
  `:from`, `:to`, `:dry_run`, `:limit` (default 100, maximum 1,000), and
  `:per_second` (positive integer, default 50).

  A missing delivery is created only for a currently enabled endpoint
  with an active subscription matching the event type and captured
  metadata. It inherits that subscription's signing mode or the
  declaration default. Conflicting matching modes return
  `:conflicting_subscriptions`. An active, type-matching subscription
  that requires filters returns `:replay_metadata_unavailable` per event
  if the row predates capture, capture is off, the metadata exceeded
  the capture limits, or an incomplete capture omits a newly declared
  filter key. Unfiltered subscriptions can use those rows.

  A pin to the recorded payload version uses the logged bytes when
  replay context proves their version. A pin to another version uses
  the declaration's variant builder when the original event can be
  reconstructed. A pinned delivery without sufficient context returns
  `:replay_payload_unavailable`. Variant builders should compute bytes
  deterministically from the event.

  New deliveries store the declaration and enqueue route. The enqueue
  callback receives `(delivery, event)` with the selected payload.
  Enable `resend_tracking :on` to persist `last_resend_by` and `last_resend_at`.
  Existing terminal rows use `AshHooks.Delivery.resend/2` with the same tenant
  and requester. Nonterminal existing rows are skipped.

  Dry run returns `{:ok, %{count: n}}` for missing deliveries that pass
  the same checks. It writes nothing and does not enqueue or rearm rows.
  Normal replay returns `{:ok, %{created: n, re_sent: n, skipped: n, errors: list}}`.
  Skipped counts live, nonterminal deliveries and missing deliveries
  with no eligible endpoint or subscription. Failures append their
  error terms to `errors` in processing order. A delivery read error never
  causes an attempt to create a replay row. Batches are spaced one second
  apart according to `:per_second`. Repeated calls can select skipped or
  failed rows again. This API returns no pagination cursor.
  """
  @spec replay(module(), struct(), keyword()) ::
          {:ok,
           %{
             created: non_neg_integer(),
             re_sent: non_neg_integer(),
             skipped: non_neg_integer(),
             errors: [term()]
           }}
          | {:ok, %{count: non_neg_integer()}}
          | {:error, term()}
  def replay(resource, endpoint, opts) do
    with {:ok, requested_by} <- validate_requested_by(opts[:requested_by]),
         {:ok, deliveries} <- require_module(opts[:deliveries], :deliveries),
         {:ok, endpoints} <- require_module(opts[:endpoints], :endpoints),
         {:ok, tenant} <-
           Tenancy.resolve([resource, endpoint.__struct__, deliveries, endpoints], opts[:tenant]),
         {:ok, {emitter, name}, declaration} <-
           replay_declaration(resource, endpoint.__struct__, deliveries, endpoints, opts),
         {:ok, tenant} <- Tenancy.resolve([resource, declaration.subscriptions], tenant),
         {:ok, events} <- replay_targets(resource, opts, tenant),
         {:ok, route} <- AshHooks.OutboundBinding.route(opts[:enqueue], opts),
         :ok <- validate_rate(opts[:per_second] || 50) do
      opts =
        Keyword.merge(opts,
          declaration: declaration,
          dispatch_source: AshHooks.OutboundBinding.source(emitter, name, endpoints),
          dispatch_route: route
        )

      if opts[:dry_run] do
        count =
          Enum.count(events, fn logged ->
            replay_one(logged, endpoint, deliveries, endpoints, requested_by, opts, tenant) ==
              :created
          end)

        {:ok, %{count: count}}
      else
        replay_events(events, endpoint, deliveries, endpoints, requested_by, opts, tenant)
      end
    end
  end

  defp replay_events(events, endpoint, deliveries, endpoints, requested_by, opts, tenant) do
    summary = %{created: 0, re_sent: 0, skipped: 0, errors: []}

    summary =
      events
      |> Enum.chunk_every(opts[:per_second] || 50)
      |> Enum.with_index()
      |> Enum.reduce(summary, fn {batch, index}, counts ->
        if index > 0, do: Process.sleep(1_000)

        Enum.reduce(batch, counts, fn logged, acc ->
          tally(
            acc,
            replay_one(logged, endpoint, deliveries, endpoints, requested_by, opts, tenant)
          )
        end)
      end)

    {:ok, Map.update!(summary, :errors, &Enum.reverse/1)}
  end

  defp validate_rate(rate) when is_integer(rate) and rate > 0, do: :ok
  defp validate_rate(_), do: {:error, :invalid_per_second}

  defp replay_one(logged, endpoint, deliveries, endpoints, requested_by, opts, tenant) do
    case fetch_delivery(deliveries, endpoint, logged, tenant) do
      :missing ->
        replay_missing(logged, endpoint, deliveries, requested_by, opts, tenant)

      {:ok, %{status: status} = row} when status in [:succeeded, :dead_letter] ->
        if opts[:dry_run],
          do: :skipped,
          else: resend_terminal(row, requested_by, endpoints, opts, tenant)

      {:ok, _live_row} ->
        :skipped

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replay_missing(logged, endpoint, deliveries, requested_by, opts, tenant) do
    entity = opts[:declaration]
    endpoint_id = PrimaryKey.scalar!(endpoint)

    with true <- logged.event_type == Atom.to_string(entity.name),
         {:match, endpoint} <-
           Dispatcher.resolve_endpoint(endpoint.__struct__, endpoint_id, tenant),
         {:ok, event, context} <- replay_event(logged),
         {:ok, subscription} <-
           Dispatcher.replay_subscription(entity, endpoint, event, context, tenant),
         {:ok, payload} <- replay_payload(event, entity, endpoint, logged.version, context) do
      if opts[:dry_run] do
        :created
      else
        event = %{event | payload: payload, metadata: event.metadata || %{}}
        persist_replay(deliveries, endpoint, subscription, event, requested_by, opts, tenant)
      end
    else
      false -> :skipped
      :skip -> :skipped
      {:error, _reason} = error -> error
    end
  end

  defp persist_replay(deliveries, endpoint, subscription, event, requested_by, opts, tenant) do
    result =
      create_replay_row(deliveries, endpoint, subscription, event, requested_by, opts, tenant)

    with {:ok, row} <- result do
      :telemetry.execute(
        [:ash_hooks, :delivery, :resend],
        %{},
        %{endpoint_id: row.endpoint_id, event_uuid: event.id, requested_by: requested_by}
      )

      _ = opts[:enqueue] && enqueue_replay(opts[:enqueue], row, event)
      :created
    end
  end

  defp replay_event(%resource{} = logged) do
    context =
      case {Extension.get_opt(resource, [:outbound_event], :replay_context, :off),
            Map.get(logged, :replay_context)} do
        {:on, %{complete: complete} = context} when is_boolean(complete) -> context
        _ -> nil
      end

    with {:ok, event} <-
           Event.new(id: logged.event_uuid, type: logged.event_type, payload: logged.payload) do
      metadata =
        case context do
          %{metadata_json: encoded} when is_binary(encoded) ->
            case Jason.decode(encoded) do
              {:ok, metadata} when is_map(metadata) -> metadata
              _ -> nil
            end

          _ ->
            nil
        end

      {:ok, %{event | metadata: metadata, version: context && context[:event_version]}, context}
    end
  end

  defp replay_payload(event, entity, endpoint, logged_version, context) do
    pin = Map.get(endpoint, :pinned_payload_version)

    cond do
      is_nil(pin) ->
        Catalog.payload(event, entity, endpoint)

      is_nil(context) or is_nil(logged_version) ->
        {:error, :replay_payload_unavailable}

      pin == logged_version or (context.complete and is_map(event.metadata)) ->
        Catalog.payload(event, %{entity | version: logged_version}, endpoint)

      true ->
        {:error, :replay_payload_unavailable}
    end
  end

  defp resend_terminal(row, requested_by, endpoints, opts, tenant) do
    case Delivery.resend(row,
           requested_by: requested_by,
           endpoints: endpoints,
           enqueue: opts[:enqueue],
           tenant: tenant
         ) do
      {:ok, _} -> :re_sent
      {:error, reason} -> {:error, reason}
    end
  end

  defp tally(acc, {:error, reason}), do: Map.update!(acc, :errors, &[reason | &1])
  defp tally(acc, outcome), do: Map.update!(acc, outcome, &(&1 + 1))

  defp replay_declaration(resource, endpoint_module, deliveries, endpoints, opts)
       when endpoint_module == endpoints do
    case opts[:declaration] do
      {emitter, name} when is_atom(emitter) and is_atom(name) ->
        with %{events: ^resource, deliveries: ^deliveries} = entity <-
               AshHooks.Info.outbound(emitter, name),
             ^endpoints <-
               Extension.get_opt(entity.subscriptions, [:subscription], :endpoint_resource, nil) do
          {:ok, {emitter, name}, entity}
        else
          _ -> {:error, :declaration_mismatch}
        end

      _ ->
        {:error, :declaration_required}
    end
  end

  defp replay_declaration(_resource, _endpoint_module, _deliveries, _endpoints, _opts),
    do: {:error, :declaration_mismatch}

  defp enqueue_replay(enqueue, row, event) do
    case enqueue do
      {m, f} -> apply(m, f, [row, event])
      fun when is_function(fun, 2) -> fun.(row, event)
    end
  end

  defp fetch_delivery(deliveries, endpoint, logged, tenant) do
    require Ash.Expr

    ref = Ash.Expr.ref(:endpoint_id)
    uuid = Ash.Expr.ref(:event_uuid)

    expression =
      Ash.Expr.expr(^ref == ^PrimaryKey.scalar!(endpoint) and ^uuid == ^logged.event_uuid)

    AshHooks.Phase.run(
      deliveries
      |> Ash.Query.do_filter(expression),
      tenant,
      &Ash.read_one(&1, authorize?: false, tenant: tenant)
    )
    |> case do
      {:ok, nil} -> :missing
      {:ok, row} -> {:ok, row}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_replay_row(deliveries, endpoint, subscription, event, requested_by, opts, tenant) do
    input =
      %{
        event_uuid: event.id,
        event_type: event.type,
        endpoint_id: PrimaryKey.scalar!(endpoint),
        subscription_id: PrimaryKey.scalar!(subscription),
        signing_mode: subscription.signing_mode || opts[:declaration].signing_mode || :standard,
        dispatch_source: opts[:dispatch_source],
        dispatch_route: opts[:dispatch_route]
      }
      |> Map.put(AshHooks.Info.payload_attribute(deliveries), event.payload)

    changeset =
      Ash.Changeset.for_create(deliveries, :dispatch, input, authorize?: false, tenant: tenant)

    changeset =
      if Ash.Resource.Info.attribute(deliveries, :last_resend_by) do
        Ash.Changeset.force_change_attributes(changeset,
          last_resend_by: requested_by,
          last_resend_at: DateTime.utc_now()
        )
      else
        changeset
      end

    AshHooks.Phase.run(deliveries, tenant, fn ->
      Ash.create(changeset,
        context: AshHooks.Phase.context(deliveries),
        authorize?: false,
        tenant: tenant
      )
    end)
  end

  defp replay_targets(resource, opts, tenant) do
    limit = Keyword.get(opts, :limit, 100)

    with :ok <- validate_replay_limit(limit) do
      cond do
        is_binary(uuid = opts[:event_uuid]) ->
          single_target(resource, uuid, tenant)

        is_binary(type = opts[:event_type]) ->
          AshHooks.Phase.run(
            resource
            |> Ash.Query.filter(event_type == ^type)
            |> replay_time_filters(opts)
            |> Ash.Query.sort(inserted_at: :asc)
            |> Ash.Query.limit(limit),
            tenant,
            &Ash.read(&1, authorize?: false, tenant: tenant)
          )

        true ->
          {:error, :event_filter_required}
      end
    end
  end

  defp replay_time_filters(query, opts) do
    query
    |> replay_bound(:inserted_at, opts[:from], :>=)
    |> replay_bound(:inserted_at, opts[:to], :<=)
  end

  defp replay_bound(query, _field, nil, _op), do: query

  defp replay_bound(query, field, bound, op) do
    require Ash.Expr
    ref = Ash.Expr.ref(field)
    expression = Ash.Expr.expr(^ref >= ^bound)
    expression = if op == :<=, do: Ash.Expr.expr(^ref <= ^bound), else: expression
    Ash.Query.filter(query, ^expression)
  end

  defp single_target(resource, uuid, tenant) do
    AshHooks.Phase.run(
      resource
      |> Ash.Query.filter(event_uuid == ^uuid),
      tenant,
      &Ash.read_one(&1, authorize?: false, tenant: tenant)
    )
    |> case do
      {:ok, nil} -> {:error, :event_not_found}
      {:ok, logged} -> {:ok, [logged]}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_replay_limit(limit) when is_integer(limit) and limit in 1..1_000, do: :ok
  defp validate_replay_limit(_invalid), do: {:error, :invalid_limit}

  defp validate_requested_by(requested_by)
       when is_binary(requested_by) and requested_by != "" and byte_size(requested_by) <= 255,
       do: {:ok, requested_by}

  defp validate_requested_by(_invalid), do: {:error, :requested_by_required}

  defp require_module(module, _name) when is_atom(module) and not is_nil(module),
    do: {:ok, module}

  defp require_module(_invalid, name),
    do: {:error, UnknownError.exception(error: "replay requires the #{inspect(name)} resource")}

  @section %Spark.Dsl.Section{
    name: :outbound_event,
    describe: "Configuration of the outbound event log.",
    schema: [
      replay_context: [
        type: {:in, [:off, :on]},
        default: :off,
        doc: "Persist the declared filter metadata and payload-version context for replay."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@section],
    transformers: [
      AshHooks.OutboundEvent.Transformers.AddEventFields,
      AshHooks.OutboundEvent.Transformers.AddEventIdentity,
      AshHooks.OutboundEvent.Transformers.AddEventActions
    ],
    verifiers: [AshHooks.Verifiers.InjectedAttributes, AshHooks.Verifiers.MultitenancyNoBypass]
end
