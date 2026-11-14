defmodule AshHooks.KeyLifecycle do
  @moduledoc false

  alias Ash.Resource.Info, as: ResourceInfo
  alias Spark.Dsl.Extension

  require Ash.Query

  alias AshHooks.Errors.Unknown.UnknownError
  alias AshHooks.{PrimaryKey, Tenancy}

  @spec roll_secret(struct(), keyword()) :: {:ok, struct()} | {:error, term()}
  def roll_secret(endpoint, opts \\ []) do
    resource = endpoint.__struct__

    with {:ok, new_ref} <- validate_new_secret_ref(endpoint, opts[:new_secret_ref]),
         :ok <- require_lifecycle(resource),
         {:ok, tenant} <- Tenancy.resolve([resource], opts[:tenant]),
         {:ok, overlap} <- validate_overlap(resource, opts) do
      rolled_at = opts[:now] || DateTime.utc_now()
      rolled_at = DateTime.truncate(rolled_at, :microsecond)
      retired_at = DateTime.add(rolled_at, overlap, :second)

      result =
        resource
        |> Ash.Query.do_filter(PrimaryKey.filter(endpoint))
        |> Ash.Query.filter(
          secret_ref == ^endpoint.secret_ref and
            (is_nil(previous_secret_ref) or previous_secret_retired_at <= ^rolled_at)
        )
        |> Ash.bulk_update(
          :roll_secret,
          %{
            new_secret_ref: new_ref,
            old_ref: endpoint.secret_ref,
            old_created_at: endpoint.secret_created_at,
            retired_at: retired_at,
            rolled_at: rolled_at
          },
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
          roll_conflict(endpoint, tenant, rolled_at)

        %Ash.BulkResult{} = result ->
          {:error, List.first(result.errors || []) || result}
      end
    end
  end

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

  defp roll_conflict(endpoint, tenant, now) do
    with {:ok, current} <-
           endpoint.__struct__
           |> Ash.Query.do_filter(PrimaryKey.filter(endpoint))
           |> Ash.read_one(authorize?: false, tenant: tenant) do
      {:error, conflict_reason(current, endpoint.secret_ref, now)}
    end
  end

  # The incumbent is unchanged and still holds a previous key: an undated
  # one refuses until resolved, a dated one inside its window is an active
  # overlap. Anything else means another writer rolled underneath.
  defp conflict_reason(
         %{secret_ref: incumbent, previous_secret_ref: previous, previous_secret_retired_at: nil},
         incumbent,
         _now
       )
       when not is_nil(previous),
       do: :previous_secret_undated

  defp conflict_reason(
         %{secret_ref: incumbent, previous_secret_ref: previous, previous_secret_retired_at: at},
         incumbent,
         now
       )
       when not is_nil(previous) do
    if DateTime.compare(at, now) == :gt, do: :overlap_active, else: :rolled_underneath
  end

  defp conflict_reason(_current, _incumbent, _now), do: :rolled_underneath

  @spec schedule_previous_retirement(struct(), DateTime.t(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def schedule_previous_retirement(endpoint, at, opts \\ []) do
    resource = endpoint.__struct__

    with :ok <- require_lifecycle(resource),
         {:ok, tenant} <- Tenancy.resolve([resource], opts[:tenant]),
         :ok <- require_previous_secret(endpoint),
         {:ok, at} <- validate_retirement_time(at, opts[:now] || DateTime.utc_now(), resource) do
      resource
      |> Ash.Query.do_filter(PrimaryKey.filter(endpoint))
      |> Ash.Query.filter(previous_secret_ref == ^endpoint.previous_secret_ref)
      |> Ash.bulk_update(:schedule_previous_retirement, %{retired_at: at},
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

  defp require_previous_secret(%{previous_secret_ref: nil}), do: {:error, :no_previous_secret}
  defp require_previous_secret(_endpoint), do: :ok

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
  def expire_previous_secret(endpoint, opts \\ []) do
    resource = endpoint.__struct__

    with :ok <- require_lifecycle(resource),
         {:ok, tenant} <- Tenancy.resolve([resource], opts[:tenant]) do
      expire_previous_secret_gated(endpoint, tenant, opts[:now] || DateTime.utc_now())
    end
  end

  defp expire_previous_secret_gated(endpoint, tenant, retired_at) do
    resource = endpoint.__struct__

    if is_nil(endpoint.previous_secret_ref) do
      {:ok, endpoint}
    else
      result =
        resource
        |> Ash.Query.do_filter(PrimaryKey.filter(endpoint))
        |> Ash.Query.filter(previous_secret_ref == ^endpoint.previous_secret_ref)
        |> Ash.bulk_update(
          :retire_previous_secret,
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
  def expire_previous_secrets(resource, opts \\ []) do
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)

    with :ok <- require_lifecycle(resource),
         {:ok, tenant} <- Tenancy.resolve([resource], opts[:tenant]) do
      result =
        resource
        |> Ash.Query.filter(
          not is_nil(previous_secret_ref) and previous_secret_retired_at <= ^now
        )
        |> Ash.bulk_update(:retire_previous_secret, %{retired_at: now},
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
  end

  defp validate_new_secret_ref(endpoint, ref) do
    cond do
      not (is_binary(ref) and ref != "") ->
        {:error, :new_secret_ref_required}

      ref == endpoint.secret_ref ->
        {:error, :same_reference}

      true ->
        {:ok, ref}
    end
  end

  defp require_lifecycle(resource) do
    if lifecycle?(resource) do
      :ok
    else
      {:error, lifecycle_error(resource)}
    end
  end

  defp lifecycle?(resource), do: ResourceInfo.attribute(resource, :secret_created_at) != nil

  defp lifecycle_error(resource) do
    UnknownError.exception(
      error:
        inspect(resource) <>
          " does not carry the key-lifecycle columns (key_lifecycle :off); " <>
          "declare `key_lifecycle :on` under `endpoint` and migrate the six " <>
          "columns to roll signing secrets"
    )
  end
end
