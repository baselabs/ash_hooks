defmodule AshHooks.KeyRegistry.Transitions do
  @moduledoc false
  alias Ash.Resource.Info
  alias AshHooks.{Custody, PrimaryKey, Tenancy}
  alias AshHooks.KeyRegistry.Storage
  require Ash.Query
  require Ash.Expr

  def issue(owner, kind, opts) do
    registry = Storage.registry(owner)

    with :ok <- Storage.check(registry, owner),
         :ok <- outside_transaction(owner),
         {:ok, tenant} <- Tenancy.resolve([registry], opts[:tenant]),
         {:ok, custody_tenant} <- Custody.canonical_tenant(tenant, owner, opts) do
      now = now(opts)

      Storage.phase(registry, owner, tenant, fn ->
        registry
        |> Ash.Changeset.for_create(
          :issue_key,
          %{
            ref: "ahk_" <> Ash.UUIDv7.generate(),
            kind: kind,
            owner_resource: owner,
            custody_tenant: custody_tenant,
            issued_at: now,
            inserted_at: now,
            updated_at: now
          },
          tenant: tenant
        )
        |> Ash.Changeset.set_context(Storage.context(registry))
        |> Ash.create(authorize?: false)
      end)
    end
  end

  def attach(owner, ref, opts) do
    registry = Storage.registry(owner)

    with :ok <- Storage.check(registry, owner),
         {:ok, tenant} <- Tenancy.resolve([registry], opts[:tenant]) do
      Storage.phase(registry, owner, tenant, fn ->
        attach_in_phase(registry, owner, ref, tenant, opts)
      end)
    end
  end

  defp attach_in_phase(registry, owner, ref, tenant, opts) do
    query = registry |> Storage.query() |> Ash.Query.filter(ref == ^ref)

    with {:ok, row} <- owner_by_ref(owner, ref, tenant),
         {:ok, canonical} <- Custody.canonical_tenant(owner_tenant(row), owner, opts),
         {:ok, issued} <- Ash.read_one(query, authorize?: false, tenant: tenant),
         :ok <- matching_tenant(issued, canonical),
         {:ok, rows} <-
           cas(
             Ash.Query.filter(query, state == :issued),
             %{
               state: :attached,
               owner_resource: row.__struct__,
               owner_key: PrimaryKey.encode(row)
             },
             tenant
           ) do
      case rows do
        [attached] -> {:ok, attached}
        [] -> {:error, :key_issue_expired}
      end
    end
  end

  defp matching_tenant(nil, _canonical), do: {:error, :key_issue_expired}
  defp matching_tenant(%{custody_tenant: canonical}, canonical), do: :ok
  defp matching_tenant(_issued, _canonical), do: {:error, :tenancy_mismatch}

  def retire(owner, ref, destroy_after, opts) do
    registry = Storage.registry(owner)

    with :ok <- Storage.check(registry, owner) do
      query = registry |> Storage.query() |> Ash.Query.filter(ref == ^ref and state == :attached)

      with {:ok, _} <- cas(query, %{state: :retired, destroy_after: destroy_after}, opts[:tenant]),
           do: :ok
    end
  end

  def cleanup(owner, ref, opts) do
    registry = Storage.registry(owner)

    with :ok <- Storage.check(registry, owner),
         :ok <- outside_transaction(owner),
         {:ok, _} <-
           Storage.phase(registry, owner, opts[:tenant], fn ->
             retire_issued(registry, ref, opts)
           end),
         do: :ok
  end

  defp retire_issued(registry, ref, opts) do
    query = registry |> Storage.query() |> Ash.Query.filter(ref == ^ref and state == :issued)
    cas(query, %{state: :retired, destroy_after: now(opts)}, opts[:tenant])
  end

  def cas(query, values, tenant) do
    values = Map.put_new(values, :updated_at, DateTime.utc_now())

    case Ash.bulk_update(query, :transition_key, values,
           authorize?: false,
           tenant: tenant,
           return_records?: true,
           return_errors?: true,
           strategy: [:atomic],
           context: Storage.context(query.resource)
         ) do
      %Ash.BulkResult{status: :success, records: rows} -> {:ok, rows}
      %Ash.BulkResult{errors: [error | _]} -> {:error, error}
    end
  end

  def outside_transaction(resource),
    do: if(Ash.DataLayer.in_transaction?(resource), do: {:error, :inside_transaction}, else: :ok)

  def now(opts), do: DateTime.truncate(Keyword.get(opts, :now, DateTime.utc_now()), :microsecond)

  def owner_by_ref(owner, ref, tenant) do
    filter =
      Enum.reduce(slots(owner), false, fn {field, kind}, filter ->
        Ash.Expr.expr(
          ^filter or (^Ash.Expr.ref(field) == ^ref and not is_nil(^Ash.Expr.ref(kind)))
        )
      end)

    case owner
         |> Storage.query()
         |> Ash.Query.filter(^filter)
         |> Ash.read_one(authorize?: false, tenant: tenant) do
      {:ok, nil} -> {:error, :key_issue_expired}
      result -> result
    end
  end

  def slots(owner) do
    for {ref, kind} <- [
          {:secret_ref, :secret_kind},
          {:previous_secret_ref, :previous_secret_kind},
          {:legacy_secret_ref, :legacy_secret_kind},
          {:legacy_previous_secret_ref, :legacy_previous_secret_kind}
        ],
        Info.attribute(owner, kind),
        do: {ref, kind}
  end

  def owner_tenant(%owner{} = row) do
    case Info.multitenancy_attribute(owner) do
      nil -> nil
      attribute -> Map.fetch!(row, attribute)
    end
  end
end
