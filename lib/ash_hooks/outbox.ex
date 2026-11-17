defmodule AshHooks.Outbox do
  @moduledoc false

  require Ash.Query

  alias AshHooks.{Event, Info, OutboundBinding, Phase, PrimaryKey, Tenancy}
  alias AshHooks.OutboundOutbox.Metadata
  alias Spark.Dsl.Extension

  @type fanout_result :: :done | {:pending, term()} | :failed | :busy | :stale | :missing | {:error, term()}
  @type sweep_summary :: %{done: non_neg_integer(), pending: non_neg_integer(), failed: non_neg_integer(), busy: non_neg_integer(), stale: non_neg_integer(), missing: non_neg_integer(), errors: [term()]}

  def option(resource, key), do: Extension.get_opt(resource, [:outbox], key)

  def publish(resource, declaration, event, opts) do
    emit(:publish, %{event_uuid: event_id(event)}, :attempt)

    with {:ok, emitter, name, entity, endpoint} <- declaration(resource, declaration),
         {:ok, event} <- event(event, name),
         :ok <- Metadata.validate(event.metadata),
         {:ok, tenant} <- tenant(resource, entity, endpoint, opts),
         :ok <- atomicity(resource, opts[:caller_resource], opts),
         {:ok, route} <- publication_route(resource, Keyword.get(opts, :route, :default)) do
      input = %{
        event_uuid: event.id, event_type: event.type, payload: event.payload,
        version: entity.version || 1, metadata: event.metadata, format_version: 1,
        acceptance_token: Ash.UUID.generate(), next_attempt_at: now(),
        dispatch_source: OutboundBinding.source(emitter, name, endpoint), dispatch_route: route
      }

      persist(resource, input, tenant, opts)
    else
      {:error, reason} = error ->
        emit(:publish, %{event_uuid: event_id(event)}, :refused, reason)
        error
    end
  end

  defp persist(resource, input, tenant, opts) do
    # Raw repo transactions cannot deliver after-commit Ash notifications. Return
    # them so Ash never warns or raises about a notification it cannot send.
    raw? = Ash.DataLayer.in_transaction?(resource) and not Process.get(:ash_started_transaction?, false)
    return? = raw? or Keyword.get(opts, :return_notifications?, false)
    context = Map.merge(opts[:context] || %{}, Phase.context(resource))

    result = Ash.create(resource, input, action: :publish, authorize?: false, tenant: tenant,
      context: context, return_notifications?: return?, rollback_on_error?: false)

    case result do
      {:ok, row} -> disposition(row, input)
      {:ok, row, _notifications} -> disposition(row, input)
      {:error, reason} ->
        emit(:publish, %{event_uuid: input.event_uuid}, :refused, reason)
        {:error, reason}
    end
  end

  defp disposition(row, input) do
    keys = [:dispatch_source, :dispatch_route, :event_type, :version, :payload, :metadata, :format_version]

    if Map.take(row, keys) === Map.take(input, keys) do
      {:ok, if(row.acceptance_token == input.acceptance_token, do: :accepted, else: :duplicate)}
    else
      emit(:publish, row, :refused, :publication_conflict)
      {:error, :publication_conflict}
    end
  end

  def atomicity(resource, caller, opts \\ []) do
    layer = Ash.DataLayer.data_layer(resource)

    cond do
      layer not in [AshPostgres.DataLayer, AshSqlite.DataLayer] or not Ash.DataLayer.can?(:transact, resource) ->
        {:error, :nontransactional_outbox}
      caller && (Ash.DataLayer.data_layer(caller) != layer or Phase.repo(caller) != Phase.repo(resource)) ->
        {:error, :publication_repository_mismatch}
      opts[:dynamic_repo] && opts[:dynamic_repo] != Phase.repo(resource).get_dynamic_repo() ->
        {:error, :publication_repository_mismatch}
      true -> :ok
    end
  end

  def fanout(resource, id, opts) do
    with {:ok, tenant} <- Tenancy.resolve([resource], opts[:tenant]),
         :ok <- Phase.outside_transaction(resource),
         {:ok, row} <- fetch(resource, id, tenant) do
      case row do
        nil -> :missing
        %{state: :done} -> :done
        %{state: :failed} -> :failed
        row -> claim(row, tenant)
      end
    end
  end

  defp claim(row, tenant) do
    time = now()
    token = Ash.UUID.generate()
    lease = DateTime.add(time, option(row.__struct__, :fanout_lease_seconds), :second)

    row
    |> owned_query()
    |> Ash.Query.filter(state == :pending and next_attempt_at <= ^time and
      (is_nil(lease_expires_at) or lease_expires_at <= ^time))
    |> update(:claim, %{claim_token: token, lease_expires_at: lease}, tenant)
    |> case do
      {:ok, nil} ->
        emit(:claim, row, :busy)
        :busy
      {:ok, claimed} ->
        emit(:publish, claimed, :accepted)
        emit(:claim, claimed, :claimed)
        run(claimed, tenant)
      {:error, reason} -> {:error, reason}
    end
  end

  defp run(row, tenant) do
    owner = self()
    ref = make_ref()
    resources = Enum.map(option(row.__struct__, :declarations), &elem(&1, 0))
    repositories = Enum.map([row.__struct__ | resources], &repository_binding/1) |> Enum.reject(&is_nil/1)

    {pid, monitor} = spawn_monitor(fn ->
      Enum.each(repositories, fn {repo, instance} -> repo.put_dynamic_repo(instance) end)
      send(owner, {ref, safely(fn -> dispatch(row, tenant) end)})
    end)

    timeout = option(row.__struct__, :fanout_timeout)
    # The guardian also kills the runner if the caller dies. No child can keep
    # writing after its owning invocation or its deadline has gone away.
    guardian = spawn(fn -> guard(owner, pid, timeout) end)

    result = receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result
      {:DOWN, ^monitor, :process, ^pid, _reason} -> {:error, :fanout_crashed}
    after
      timeout ->
        Process.exit(pid, :kill)
        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        end
        {:error, :fanout_timeout}
    end

    Process.exit(guardian, :kill)
    complete(row, tenant, result)
  end

  defp guard(owner, runner, timeout) do
    owner_ref = Process.monitor(owner)
    runner_ref = Process.monitor(runner)
    receive do
      {:DOWN, ^owner_ref, :process, ^owner, _reason} -> Process.exit(runner, :kill)
      {:DOWN, ^runner_ref, :process, ^runner, _reason} -> :ok
    after
      timeout -> Process.exit(runner, :kill)
    end
  end

  defp repository_binding(resource) do
    if Ash.DataLayer.data_layer(resource) in [AshPostgres.DataLayer, AshSqlite.DataLayer] do
      repo = Phase.repo(resource)
      {repo, repo.get_dynamic_repo()}
    end
  end

  defp dispatch(row, tenant) do
    with :ok <- decode(row),
         {:ok, emitter, name, _entity, _endpoint} <- stored_declaration(row),
         {:ok, callback} <- stored_route(row),
         {:ok, event} <- Event.new(id: row.event_uuid, type: row.event_type, payload: row.payload, metadata: row.metadata) do
      AshHooks.Dispatcher.dispatch(emitter, name, %{event | version: row.version},
        tenant: tenant, enqueue: callback, outbox_admission?: true)
    end
  end

  defp decode(%{format_version: 1} = row) do
    with :ok <- Metadata.validate(row.metadata),
         true <- is_integer(row.version) and row.version > 0,
         {:ok, _event} <- Event.new(id: row.event_uuid, type: row.event_type, payload: row.payload, metadata: row.metadata) do
      :ok
    else
      _invalid -> {:error, :invalid_publication_content}
    end
  end

  defp decode(_row), do: {:error, :unsupported_publication_format}

  defp complete(row, tenant, {:ok, results}) do
    case Enum.find(results, &(&1.status not in [:created, :duplicate, :reconciled, :deferred])) do
      nil -> transition(row, tenant, :finish, %{completed_at: now()}, :done)
      result -> retry(row, tenant, result.error || :fanout_incomplete)
    end
  end

  defp complete(row, tenant, {:error, reason}), do: retry(row, tenant, reason)

  defp retry(row, tenant, reason) do
    error = AshHooks.Telemetry.classify_token(reason)
    if reason in [:unsupported_publication_format, :invalid_publication_content] or row.attempts >= option(row.__struct__, :fanout_max_attempts) do
      transition(row, tenant, :park, %{failed_at: now(), last_error: error}, :failed)
    else
      delay = min(option(row.__struct__, :fanout_max_backoff_seconds),
        option(row.__struct__, :fanout_base_backoff_seconds) * Integer.pow(2, min(row.attempts - 1, 30)))
      transition(row, tenant, :release,
        %{next_attempt_at: DateTime.add(now(), delay, :second), last_error: error}, {:pending, reason})
    end
  end

  defp transition(row, tenant, action, input, outcome) do
    time = now()
    row
    |> owned_query()
    |> Ash.Query.filter(state == :pending and claim_token == ^row.claim_token and lease_expires_at > ^time)
    |> update(action, Map.put(input, :claim_token, row.claim_token), tenant)
    |> case do
      {:ok, nil} ->
        emit(:claim, row, :stale)
        :stale
      {:ok, updated} ->
        {status, reason} = if is_tuple(outcome), do: outcome, else: {outcome, nil}
        emit(:result, updated, status, reason)
        outcome
      {:error, reason} -> {:error, {:publication_transition_failed, reason}}
    end
  end

  def fanout_pending(resource, batch_size, opts) do
    opts = Keyword.put(opts, :batch_size, batch_size)
    with {:ok, tenant} <- Tenancy.resolve([resource], opts[:tenant]),
         :ok <- Phase.outside_transaction(resource),
         {:ok, rows} <- list(resource, Keyword.merge(opts, state: :pending, due?: true)) do
      summary = %{done: 0, pending: 0, failed: 0, busy: 0, stale: 0, missing: 0, errors: []}
      summary = Enum.reduce(rows, summary, fn row, acc ->
        case safely(fn -> fanout(resource, row.event_uuid, tenant: tenant) end) do
          {:pending, _reason} -> Map.update!(acc, :pending, &(&1 + 1))
          {:error, error} -> Map.update!(acc, :errors, &[error | &1])
          outcome -> Map.update!(acc, outcome, &(&1 + 1))
        end
      end)
      emit(:sweep, %{}, :complete)
      {:ok, summary}
    else
      {:error, reason} = error ->
        emit(:sweep, %{}, :error, reason)
        error
    end
  end

  def rearm(resource, id, opts) do
    with {:ok, tenant} <- Tenancy.resolve([resource], opts[:tenant]),
         {:ok, row} <- fetch(resource, id, tenant) do
      rearm_row(row, tenant)
    end
  end

  defp rearm_row(nil, _tenant), do: {:error, :publication_missing}
  defp rearm_row(row, tenant) do
    row
    |> owned_query()
    |> Ash.Query.filter(state == :failed)
    |> update(:rearm, %{next_attempt_at: now()}, tenant)
    |> case do
      {:ok, nil} -> {:error, :publication_not_failed}
      {:ok, updated} ->
        emit(:rearm, updated, :pending)
        {:ok, updated}
      {:error, reason} -> {:error, reason}
    end
  end

  def list(resource, opts) do
    state = Keyword.get(opts, :state, :pending)
    limit = Keyword.get(opts, :batch_size, 100)
    with {:ok, tenant} <- Tenancy.resolve([resource], opts[:tenant]),
         true <- state in [:pending, :failed] and is_integer(limit) and limit in 1..5_000 do
      time = now()
      query = resource |> Ash.Query.filter(state == ^state) |> Ash.Query.sort(next_attempt_at: :asc, event_uuid: :asc) |> Ash.Query.limit(limit)
      query = if opts[:due?], do: Ash.Query.filter(query, next_attempt_at <= ^time and (is_nil(lease_expires_at) or lease_expires_at <= ^time)), else: query
      Phase.run(query, tenant, &Ash.read(&1, authorize?: false, tenant: tenant, page: false))
    else
      false -> {:error, :invalid_outbox_query}
      {:error, reason} -> {:error, reason}
    end
  end

  def prune(resource, opts) do
    with {:ok, tenant} <- Tenancy.resolve([resource], opts[:tenant]) do
      limit = Keyword.get(opts, :batch_size, 500)
      cutoff = DateTime.add(now(), -option(resource, :deduplication_horizon_seconds), :second)
      query = resource |> Ash.Query.filter(state == :done and completed_at < ^cutoff) |> Ash.Query.limit(limit)
      case Phase.bulk(query, tenant, &Ash.bulk_destroy(&1, :prune, %{}, authorize?: false,
        tenant: tenant, strategy: [:atomic], return_records?: true, return_errors?: true)) do
        %Ash.BulkResult{status: :success, records: rows} -> {:ok, length(rows)}
        %Ash.BulkResult{} = result -> {:error, List.first(result.errors || []) || result}
      end
    end
  end

  defp fetch(resource, id, tenant), do: Phase.run(Ash.Query.filter(resource, event_uuid == ^id), tenant, &Ash.read_one(&1, authorize?: false, tenant: tenant))

  defp owned_query(row) do
    row.__struct__ |> Ash.Query.do_filter(PrimaryKey.filter(row))
    |> Ash.Query.filter(dispatch_source == ^row.dispatch_source and dispatch_route == ^row.dispatch_route)
  end

  defp update(query, action, input, tenant) do
    case Phase.bulk(query, tenant, &Ash.bulk_update(&1, action, input, authorize?: false, tenant: tenant,
      strategy: [:atomic], return_records?: true, return_errors?: true)) do
      %Ash.BulkResult{status: :success, records: [row]} -> {:ok, row}
      %Ash.BulkResult{status: :success, records: []} -> {:ok, nil}
      %Ash.BulkResult{} = result -> {:error, List.first(result.errors || []) || result}
    end
  end

  defp declaration(resource, {emitter, name} = declaration) do
    if declaration in option(resource, :declarations) do
      case Info.outbound(emitter, name) do
        %{subscriptions: subscriptions, deliveries: deliveries} = entity when not is_nil(subscriptions) and not is_nil(deliveries) ->
          endpoint = Extension.get_opt(subscriptions, [:subscription], :endpoint_resource)
          {:ok, emitter, name, entity, endpoint}
        _unknown -> {:error, :unknown_declaration}
      end
    else
      {:error, :unknown_declaration}
    end
  end
  defp declaration(_resource, _declaration), do: {:error, :unknown_declaration}

  defp stored_declaration(row) do
    Enum.find_value(option(row.__struct__, :declarations), {:error, :unknown_declaration}, fn entry ->
      case declaration(row.__struct__, entry) do
        {:ok, emitter, name, _entity, endpoint} = result ->
          if OutboundBinding.source(emitter, name, endpoint) == row.dispatch_source, do: result
        _unknown -> nil
      end
    end)
  end

  defp publication_route(resource, name) do
    routes = option(resource, :delivery_routes)
    name = if is_atom(name), do: Atom.to_string(name), else: name
    case Enum.find(routes, fn {key, _value} -> Atom.to_string(key) == name end) do
      nil -> {:error, :unresolved_route}
      {_key, callback} -> OutboundBinding.route(callback, [])
    end
  end

  defp stored_route(row) do
    Enum.find_value(option(row.__struct__, :delivery_routes), {:error, :unresolved_route}, fn {_name, callback} ->
      if OutboundBinding.route(callback, []) == {:ok, row.dispatch_route}, do: {:ok, callback}
    end)
  end

  defp tenant(resource, entity, endpoint, opts),
    do: Tenancy.resolve(Enum.reject([resource, entity.subscriptions, entity.deliveries, endpoint, entity.events], &is_nil/1), opts[:tenant])

  defp event(%Event{} = event, name) do
    with {:ok, checked} <- Event.new(Map.from_struct(event)),
         true <- checked.type == Atom.to_string(name) do
      {:ok, checked}
    else
      _invalid -> {:error, :invalid_event}
    end
  end
  defp event(_event, _name), do: {:error, :invalid_event}
  defp event_id(%Event{id: id}), do: id
  defp event_id(_event), do: nil
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp safely(operation) do
    operation.()
  rescue
    _error -> {:error, :fanout_crashed}
  catch
    _kind, _reason -> {:error, :fanout_crashed}
  end

  def emit(event, row, outcome, reason \\ nil) do
    :telemetry.execute([:ash_hooks, :outbox, event], %{count: 1},
      %{event_uuid: Map.get(row, :event_uuid), outcome: outcome,
        reason: if(reason, do: AshHooks.Telemetry.classify_token(reason))})
  end
end
