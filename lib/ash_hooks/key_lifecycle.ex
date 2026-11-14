defmodule AshHooks.KeyLifecycle do
  @moduledoc false

  alias Ash.Resource.Info, as: ResourceInfo
  alias Spark.Dsl.Extension

  require Ash.Query
  require Ash.Expr

  alias AshHooks.Errors.Unknown.UnknownError
  alias AshHooks.KeyRegistry.{Storage, Transitions}
  alias AshHooks.{PrimaryKey, Tenancy}

  def fields(:standard) do
    %{
      ref: :secret_ref,
      kind: :secret_kind,
      previous_kind: :previous_secret_kind,
      created_at: :secret_created_at,
      first_used_at: :secret_first_used_at,
      previous_ref: :previous_secret_ref,
      previous_created_at: :previous_secret_created_at,
      previous_first_used_at: :previous_secret_first_used_at,
      retired_at: :previous_secret_retired_at,
      roll: :roll_secret,
      retire: :retire_previous_secret,
      schedule: :schedule_previous_retirement,
      mark_current: :mark_current_secret_used,
      mark_previous: :mark_previous_secret_used,
      option: :key_lifecycle
    }
  end

  def fields(:legacy) do
    %{
      ref: :legacy_secret_ref,
      kind: :legacy_secret_kind,
      previous_kind: :legacy_previous_secret_kind,
      created_at: :legacy_secret_created_at,
      first_used_at: :legacy_secret_first_used_at,
      previous_ref: :legacy_previous_secret_ref,
      previous_created_at: :legacy_previous_secret_created_at,
      previous_first_used_at: :legacy_previous_secret_first_used_at,
      retired_at: :legacy_previous_secret_retired_at,
      roll: :roll_legacy_secret,
      retire: :retire_legacy_previous_secret,
      schedule: :schedule_legacy_previous_retirement,
      mark_current: :mark_legacy_current_secret_used,
      mark_previous: :mark_legacy_previous_secret_used,
      option: :legacy_key_lifecycle
    }
  end

  @spec roll_secret(struct(), keyword()) :: {:ok, struct()} | {:error, term()}
  def roll_secret(endpoint, opts) do
    if Storage.custodian(endpoint.__struct__) do
      fields = fields(Keyword.get(opts, :slot, :standard))

      custody_write(endpoint, opts, &roll_incumbent(&1, endpoint, opts, fields))
    else
      do_roll_secret(endpoint, opts)
    end
  end

  defp roll_incumbent(current, endpoint, opts, fields) do
    if Map.fetch!(current, fields.ref) == Map.fetch!(endpoint, fields.ref),
      do: do_roll_secret(current, opts),
      else: {:error, :rolled_underneath}
  end

  defp do_roll_secret(endpoint, opts) do
    resource = endpoint.__struct__
    fields = fields(Keyword.get(opts, :slot, :standard))

    with {:ok, new_ref} <- validate_new_secret_ref(endpoint, opts[:new_secret_ref], fields),
         :ok <- require_lifecycle(resource, fields),
         {:ok, tenant} <- Tenancy.resolve([resource], opts[:tenant]),
         {:ok, overlap} <- validate_overlap(resource, opts) do
      rolled_at = opts[:now] || DateTime.utc_now()
      rolled_at = DateTime.truncate(rolled_at, :microsecond)
      incumbent = Map.fetch!(endpoint, fields.ref)
      retired_at = scheduled_retirement(incumbent, rolled_at, overlap)

      fence = incumbent_fence(fields, incumbent)

      params = %{
        new_secret_ref: new_ref,
        old_ref: incumbent,
        old_created_at: Map.fetch!(endpoint, fields.created_at),
        retired_at: retired_at,
        rolled_at: rolled_at
      }

      params = roll_kind_argument(params, endpoint, fields)

      result =
        lifecycle_query(resource, tenant)
        |> Ash.Query.do_filter(PrimaryKey.filter(endpoint))
        |> Ash.Query.filter(
          ^fence and
            (is_nil(^Ash.Expr.ref(fields.previous_ref)) or
               ^Ash.Expr.ref(fields.retired_at) <= ^rolled_at)
        )
        |> Ash.bulk_update(
          fields.roll,
          params,
          authorize?: false,
          return_records?: true,
          return_errors?: true,
          strategy: [:atomic],
          tenant: tenant
        )

      case result do
        %Ash.BulkResult{status: :success, records: [rolled]} ->
          :telemetry.execute(
            [:ash_hooks, :endpoint, :roll],
            %{},
            %{endpoint_id: PrimaryKey.scalar!(endpoint)}
          )

          {:ok, rolled}

        %Ash.BulkResult{status: :success, records: []} ->
          roll_conflict(endpoint, tenant, rolled_at, fields)

        %Ash.BulkResult{} = result ->
          {:error, List.first(result.errors || []) || result}
      end
    end
  end

  defp roll_kind_argument(params, endpoint, fields) do
    if Storage.custodian(endpoint.__struct__),
      do: Map.put(params, :old_kind, Map.get(endpoint, fields.kind)),
      else: params
  end

  # An empty incumbent leaves no previous key, so nothing is scheduled.
  defp scheduled_retirement(nil, _rolled_at, _overlap), do: nil

  defp scheduled_retirement(_incumbent, rolled_at, overlap),
    do: DateTime.add(rolled_at, overlap, :second)

  defp incumbent_fence(fields, nil), do: Ash.Expr.expr(is_nil(^Ash.Expr.ref(fields.ref)))

  defp incumbent_fence(fields, incumbent),
    do: Ash.Expr.expr(^Ash.Expr.ref(fields.ref) == ^incumbent)

  defp validate_overlap(resource, opts) do
    default = Extension.get_opt(resource, [:endpoint], :default_overlap_seconds, 86_400)
    # nil means "not given", as before validation existed.
    overlap =
      case Keyword.get(opts, :overlap_seconds) do
        nil -> default
        given -> given
      end

    max = Extension.get_opt(resource, [:endpoint], :max_overlap_seconds, nil)

    cond do
      not is_integer(overlap) or overlap < 0 -> {:error, :invalid_overlap}
      max && overlap > max -> {:error, {:overlap_exceeds_max, max}}
      true -> {:ok, overlap}
    end
  end

  defp roll_conflict(endpoint, tenant, now, fields) do
    with {:ok, current} <-
           lifecycle_query(endpoint.__struct__, tenant)
           |> Ash.Query.do_filter(PrimaryKey.filter(endpoint))
           |> Ash.read_one(authorize?: false, tenant: tenant) do
      {:error, conflict_reason(current, {fields, Map.fetch!(endpoint, fields.ref)}, now)}
    end
  end

  # The incumbent is unchanged and still holds a previous key: an undated
  # one refuses until resolved, a dated one inside its window is an active
  # overlap. Anything else means another writer rolled underneath.
  defp conflict_reason(current, {fields, incumbent}, now) do
    if current && Map.fetch!(current, fields.ref) == incumbent &&
         Map.fetch!(current, fields.previous_ref) do
      previous_conflict(Map.fetch!(current, fields.retired_at), now)
    else
      :rolled_underneath
    end
  end

  defp previous_conflict(nil, _now), do: :previous_secret_undated

  defp previous_conflict(at, now),
    do: if(DateTime.compare(at, now) == :gt, do: :overlap_active, else: :rolled_underneath)

  @spec schedule_previous_retirement(struct(), term(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def schedule_previous_retirement(endpoint, at, opts) do
    resource = endpoint.__struct__
    fields = fields(Keyword.get(opts, :slot, :standard))

    with :ok <- require_lifecycle(resource, fields),
         {:ok, tenant} <- Tenancy.resolve([resource], opts[:tenant]),
         :ok <- require_previous_secret(endpoint, fields),
         {:ok, at} <- validate_retirement_time(at, opts[:now] || DateTime.utc_now(), resource) do
      lifecycle_query(resource, tenant)
      |> Ash.Query.do_filter(PrimaryKey.filter(endpoint))
      |> Ash.Query.filter(
        ^Ash.Expr.ref(fields.previous_ref) == ^Map.fetch!(endpoint, fields.previous_ref)
      )
      |> Ash.bulk_update(fields.schedule, %{retired_at: at},
        authorize?: false,
        return_records?: true,
        return_errors?: true,
        strategy: [:atomic],
        tenant: tenant
      )
      |> case do
        %Ash.BulkResult{status: :success, records: [scheduled]} -> {:ok, scheduled}
        %Ash.BulkResult{status: :success, records: []} -> {:error, :previous_secret_changed}
        %Ash.BulkResult{} = result -> {:error, List.first(result.errors || []) || result}
      end
    end
  end

  defp require_previous_secret(endpoint, fields) do
    if is_nil(Map.fetch!(endpoint, fields.previous_ref)),
      do: {:error, :no_previous_secret},
      else: :ok
  end

  defp validate_retirement_time(%DateTime{} = at, now, resource) do
    at = DateTime.truncate(at, :microsecond)
    max = Extension.get_opt(resource, [:endpoint], :max_overlap_seconds, nil)

    cond do
      DateTime.compare(at, now) == :lt ->
        {:error, :retirement_in_past}

      max && DateTime.compare(at, DateTime.add(now, max, :second)) == :gt ->
        {:error, {:overlap_exceeds_max, max}}

      true ->
        {:ok, at}
    end
  end

  defp validate_retirement_time(_at, _now, _resource), do: {:error, :invalid_retirement_time}

  @spec expire_previous_secret(struct(), keyword()) :: {:ok, struct()} | {:error, term()}
  def expire_previous_secret(endpoint, opts) do
    resource = endpoint.__struct__
    fields = fields(Keyword.get(opts, :slot, :standard))

    with :ok <- require_lifecycle(resource, fields),
         {:ok, tenant} <- Tenancy.resolve([resource], opts[:tenant]) do
      expire_selected(endpoint, tenant, opts, fields)
    end
  end

  defp expire_selected(endpoint, tenant, opts, fields) do
    if Storage.custodian(endpoint.__struct__) do
      custody_write(endpoint, opts, &expire_unchanged(&1, endpoint, tenant, opts, fields))
    else
      expire_previous_secret_gated(endpoint, tenant, opts[:now] || DateTime.utc_now(), fields)
    end
  end

  defp expire_unchanged(current, endpoint, tenant, opts, fields) do
    if Map.fetch!(current, fields.previous_ref) == Map.fetch!(endpoint, fields.previous_ref),
      do: expire_previous_secret_gated(current, tenant, opts[:now] || DateTime.utc_now(), fields),
      else: {:ok, endpoint}
  end

  defp expire_previous_secret_gated(endpoint, tenant, retired_at, fields) do
    resource = endpoint.__struct__

    if is_nil(Map.fetch!(endpoint, fields.previous_ref)) do
      {:ok, endpoint}
    else
      result =
        lifecycle_query(resource, tenant)
        |> Ash.Query.do_filter(PrimaryKey.filter(endpoint))
        |> Ash.Query.filter(
          ^Ash.Expr.ref(fields.previous_ref) == ^Map.fetch!(endpoint, fields.previous_ref)
        )
        |> Ash.bulk_update(
          fields.retire,
          %{retired_at: DateTime.truncate(retired_at, :microsecond)},
          authorize?: false,
          return_records?: true,
          return_errors?: true,
          strategy: [:atomic],
          tenant: tenant
        )

      case result do
        %Ash.BulkResult{status: :success, records: [retired]} -> {:ok, retired}
        %Ash.BulkResult{status: :success, records: []} -> {:ok, endpoint}
        %Ash.BulkResult{} = result -> {:error, List.first(result.errors || []) || result}
      end
    end
  end

  @spec expire_previous_secrets(module(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def expire_previous_secrets(resource, opts) do
    fields = fields(Keyword.get(opts, :slot, :standard))
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)

    with :ok <- require_lifecycle(resource, fields),
         {:ok, tenant} <- Tenancy.resolve([resource], opts[:tenant]) do
      if Storage.custodian(resource) do
        custody_sweep(resource, fields, tenant, now, opts)
      else
        byte_sweep(resource, fields, tenant, now)
      end
    end
  end

  defp byte_sweep(resource, fields, tenant, now) do
    result =
      resource
      |> Ash.Query.filter(
        not is_nil(^Ash.Expr.ref(fields.previous_ref)) and
          ^Ash.Expr.ref(fields.retired_at) <= ^now
      )
      |> Ash.bulk_update(fields.retire, %{retired_at: now},
        authorize?: false,
        return_records?: true,
        return_errors?: true,
        strategy: [:atomic],
        tenant: tenant
      )

    case result do
      %Ash.BulkResult{status: :success, records: records} -> {:ok, length(records)}
      %Ash.BulkResult{} = result -> {:error, List.first(result.errors || []) || result}
    end
  end

  defp custody_write(endpoint, opts, write) do
    owner = endpoint.__struct__
    fields = fields(Keyword.get(opts, :slot, :standard))
    registry = Storage.registry(owner)

    with {:ok, tenant} <- Tenancy.resolve([registry], opts[:tenant]) do
      Storage.phase(registry, owner, tenant, fn ->
        custody_write_in_phase(endpoint, tenant, opts, fields, write)
      end)
    end
  end

  defp custody_write_in_phase(endpoint, tenant, opts, fields, write) do
    owner = endpoint.__struct__
    query = owner |> Storage.owner_query(tenant) |> Ash.Query.do_filter(PrimaryKey.filter(endpoint))

    query =
      if Ash.DataLayer.data_layer(owner) == AshPostgres.DataLayer,
        do: Ash.Query.lock(query, :for_update),
        else: query

    with {:ok, loaded} <- Ash.read_one(query, authorize?: false, tenant: tenant),
         current = loaded || endpoint,
         {:ok, updated} <- write.(current),
         :ok <- retire_displaced(current, fields, tenant, Transitions.now(opts)) do
      {:ok, updated}
    end
  end

  defp retire_displaced(before, fields, tenant, now) do
    ref = Map.get(before, fields.previous_ref)

    if ref && Map.get(before, fields.previous_kind) do
      retire_if_absent(before, ref, tenant, now)
    else
      :ok
    end
  end

  defp retire_if_absent(before, ref, tenant, now) do
    with {:ok, persisted} <-
           before.__struct__
           |> Storage.owner_query(tenant)
           |> Ash.Query.do_filter(PrimaryKey.filter(before))
           |> Ash.read_one(authorize?: false, tenant: tenant) do
      if Transitions.holds_ref?(persisted, ref),
        do: :ok,
        else: Transitions.retire(before.__struct__, ref, now, tenant: tenant)
    end
  end

  defp custody_sweep(resource, fields, tenant, now, opts) do
    query =
      resource
      |> Storage.owner_query(tenant)
      |> Ash.Query.filter(
        not is_nil(^Ash.Expr.ref(fields.previous_ref)) and
          ^Ash.Expr.ref(fields.retired_at) <= ^now
      )

    with :ok <- Storage.check(Storage.registry(resource), resource),
         {:ok, rows} <- Ash.read(query, authorize?: false, tenant: tenant) do
      Enum.reduce_while(rows, {:ok, 0}, &expire_candidate(&1, &2, fields, tenant, now, opts))
    end
  end

  defp expire_candidate(row, {:ok, count}, fields, tenant, now, opts) do
    result =
      custody_write(
        row,
        Keyword.merge(opts, tenant: tenant, now: now),
        &expire_if_due(&1, tenant, now, fields)
      )

    case result do
      {:ok, updated} ->
        {:cont, {:ok, count + if(Map.get(updated, fields.previous_ref) == nil, do: 1, else: 0)}}

      error ->
        {:halt, error}
    end
  end

  defp expire_if_due(current, tenant, now, fields) do
    at = Map.get(current, fields.retired_at)

    if at && DateTime.compare(at, now) != :gt,
      do: expire_previous_secret_gated(current, tenant, now, fields),
      else: {:ok, current}
  end

  defp lifecycle_query(resource, tenant) do
    if Storage.custodian(resource), do: Storage.owner_query(resource, tenant), else: Ash.Query.new(resource)
  end

  defp validate_new_secret_ref(endpoint, ref, fields) do
    cond do
      not (is_binary(ref) and ref != "") ->
        {:error, :new_secret_ref_required}

      ref in [Map.get(endpoint, fields.ref), Map.get(endpoint, fields.previous_ref)] ->
        {:error, :same_reference}

      true ->
        {:ok, ref}
    end
  end

  defp require_lifecycle(resource, fields) do
    if ResourceInfo.attribute(resource, fields.created_at) do
      :ok
    else
      {:error, lifecycle_error(resource, fields)}
    end
  end

  defp lifecycle_error(resource, fields) do
    UnknownError.exception(
      error:
        inspect(resource) <>
          " does not carry the key-lifecycle columns; declare `" <>
          Atom.to_string(fields.option) <> " :on` under `endpoint` and migrate its columns"
    )
  end
end
