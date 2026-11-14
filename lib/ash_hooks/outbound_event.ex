defmodule AshHooks.OutboundEvent do
  @moduledoc """
  Turns the consumer's resource into the outbound EVENT log: exactly one
  row per dispatched event; its id, type, declared payload version, time,
  and exact payload bytes; recorded whether or not any endpoint was
  enabled (or existed), with its own retention.

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
  is the source of record for what was EMITTED; the answer behind "what
  did we send, ever, that endpoint X never received?".

  Rows carry the exact payload bytes you dispatched; govern read access
  with your own policies. The resource needs `timestamps()` (the event's
  time is `inserted_at`), and your migration carries the table plus the
  `unique_event` index on `[:event_uuid]`.

  Policy obligation: protect the injected `:record` create and `:prune`
  destroy actions wherever your domain exposes the resource; the
  runtime's internal calls bypass authorization by design.
  """

  require Ash.Query

  alias AshHooks.{Delivery, Keyset, PrimaryKey, Tenancy}
  alias AshHooks.Errors.Unknown.UnknownError

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
             " has no :inserted_at — add `timestamps()` to its attributes " <>
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
      resource
      |> Ash.Query.filter(inserted_at < ^older_than)
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
        prune_batches(resource, older_than, tenant, batch_size, total + length(rows))

      %Ash.BulkResult{} = result ->
        {:error, List.first(result.errors || []) || result}
    end
  end

  defp prune_batches(_resource, _older_than, _tenant, _batch_size, _total),
    do: {:error, :invalid_batch_size}

  # ────────────────────────── replay ──────────────────────────

  @doc """
  Replays selected logged events to one endpoint, preserving event IDs.

  Options: required `:deliveries`, `:endpoints`, and `:requested_by`; optional
  `:enqueue`, `:tenant`, `:event_uuid`, `:event_type`, `:from`, `:to`,
  `:dry_run`, `:limit`, and `:per_second`.

  A new-row replay creates an unbound delivery and calls enqueue with
  `(logged_event, nil)`. This does not satisfy the generated worker's normal
  dispatch contract or declaration-based recovery contract. Use a callback
  that handles those arguments and drives the stored row explicitly.

  Existing terminal rows use `AshHooks.Delivery.resend/2`. That nested call
  does not forward `:tenant`, so multitenant terminal rows are skipped.
  Existing terminal rows record the requester through resend; for new rows,
  the requester is emitted only in telemetry, not stored on the delivery.
  Nonterminal existing rows are skipped. Dry run returns the selected count.
  """
  @spec replay(module(), struct(), keyword()) ::
          {:ok,
           %{created: non_neg_integer(), re_sent: non_neg_integer(), skipped: non_neg_integer()}}
          | {:error, term()}
  def replay(resource, endpoint, opts) do
    with {:ok, requested_by} <- validate_requested_by(opts[:requested_by]),
         {:ok, tenant} <- Tenancy.resolve([resource, endpoint.__struct__], opts[:tenant]),
         {:ok, deliveries} <- require_module(opts[:deliveries], :deliveries),
         {:ok, endpoints} <- require_module(opts[:endpoints], :endpoints),
         {:ok, events} <- replay_targets(resource, opts, tenant) do
      counts =
        Enum.reduce(events, {0, 0, 0}, fn logged, acc ->
          replay_one(logged, endpoint, deliveries, endpoints, requested_by, opts, tenant, acc)
        end)

      {:ok, %{created: elem(counts, 0), re_sent: elem(counts, 1), skipped: elem(counts, 2)}}
    end
  end

  defp replay_one(logged, endpoint, deliveries, endpoints, requested_by, opts, tenant, acc) do
    case fetch_delivery(deliveries, endpoint, logged, tenant) do
      :missing ->
        case create_replay_row(deliveries, endpoint, logged, tenant) do
          {:ok, _row} ->
            :telemetry.execute(
              [:ash_hooks, :delivery, :resend],
              %{},
              %{
                endpoint_id: PrimaryKey.scalar!(endpoint),
                event_uuid: logged.event_uuid,
                requested_by: requested_by
              }
            )

            _ = Keyword.get(opts, :enqueue) && enqueue_replay(opts[:enqueue], logged)
            bump(acc, 0)

          {:error, _reason} ->
            bump(acc, 2)
        end

      {:ok, %{status: status} = row} when status in [:succeeded, :dead_letter] ->
        case Delivery.resend(row,
               requested_by: requested_by,
               endpoints: endpoints,
               enqueue: opts[:enqueue],
               tenant: tenant
             ) do
          {:ok, _} -> bump(acc, 1)
          {:error, _reason} -> bump(acc, 2)
        end

      {:ok, _live_row} ->
        bump(acc, 2)
    end
  end

  defp bump({c, r, s}, index) do
    case index do
      0 -> {c + 1, r, s}
      1 -> {c, r + 1, s}
      2 -> {c, r, s + 1}
    end
  end

  defp enqueue_replay(enqueue, logged) do
    case enqueue do
      {m, f} -> apply(m, f, [logged, nil])
      fun when is_function(fun, 2) -> fun.(logged, nil)
    end
  end

  defp fetch_delivery(deliveries, endpoint, logged, tenant) do
    require Ash.Expr

    ref = Ash.Expr.ref(:endpoint_id)
    uuid = Ash.Expr.ref(:event_uuid)

    expression =
      Ash.Expr.expr(^ref == ^PrimaryKey.scalar!(endpoint) and ^uuid == ^logged.event_uuid)

    deliveries
    |> Ash.Query.do_filter(expression)
    |> Ash.read_one(authorize?: false, tenant: tenant)
    |> case do
      {:ok, nil} -> :missing
      {:ok, row} -> {:ok, row}
      {:error, _reason} -> :missing
    end
  end

  defp create_replay_row(deliveries, endpoint, logged, tenant) do
    input =
      %{
        event_uuid: logged.event_uuid,
        event_type: logged.event_type,
        endpoint_id: PrimaryKey.scalar!(endpoint),
        subscription_id: nil,
        signing_mode: :standard
      }
      |> Map.put(AshHooks.Info.payload_attribute(deliveries), logged.payload)

    Ash.create(deliveries, input, action: :dispatch, authorize?: false, tenant: tenant)
  end

  defp replay_targets(resource, opts, tenant) do
    limit = Keyword.get(opts, :limit, 100)

    with :ok <- validate_replay_limit(limit) do
      cond do
        is_binary(uuid = opts[:event_uuid]) ->
          single_target(resource, uuid, tenant)

        is_binary(type = opts[:event_type]) ->
          resource
          |> Ash.Query.filter(event_type == ^type)
          |> replay_time_filters(opts)
          |> Ash.Query.sort(inserted_at: :asc)
          |> Ash.Query.limit(limit)
          |> Ash.read(authorize?: false, tenant: tenant)

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
    resource
    |> Ash.Query.filter(event_uuid == ^uuid)
    |> Ash.read_one(authorize?: false, tenant: tenant)
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

  use Spark.Dsl.Extension,
    transformers: [
      AshHooks.OutboundEvent.Transformers.AddEventFields,
      AshHooks.OutboundEvent.Transformers.AddEventIdentity,
      AshHooks.OutboundEvent.Transformers.AddEventActions
    ],
    verifiers: [AshHooks.Verifiers.MultitenancyNoBypass]
end
