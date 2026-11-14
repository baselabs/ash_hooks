defmodule AshHooks.KeyIssuing do
  @moduledoc false

  alias AshHooks.KeyRegistry.{Storage, Transitions}
  alias AshHooks.{Phase, Tenancy}
  require Ash.Query
  require Ash.Expr

  # Specs name the owner's ref and kind attributes. Issuance and storage finish
  # before the owner write starts; only attach and retirement share its phase.
  def run(owner, specs, opts, write) do
    with :ok <- Phase.outside_transaction(owner),
         :ok <- Storage.check(Storage.registry(owner), owner),
         {:ok, tenant} <- Tenancy.resolve([owner, Storage.registry(owner)], opts[:tenant]) do
      issue_and_store(owner, specs, Keyword.put(opts, :tenant, tenant), [], write)
    end
  end

  defp issue_and_store(owner, [], opts, issued, write) do
    issued = Enum.reverse(issued)

    Storage.phase(Storage.registry(owner), owner, opts[:tenant], fn ->
      with {:ok, _result} <- write.(issued),
           {:ok, persisted} <- persisted_owner(owner, issued, opts[:tenant]),
           :ok <- attach(owner, issued, opts),
           :ok <- retire_replaced(owner, persisted, Keyword.get(opts, :retire, []), opts) do
        {:ok, persisted}
      end
    end)
  end

  defp issue_and_store(owner, [spec | rest], opts, issued, write) do
    with {:ok, row} <- Transitions.issue(owner, spec.kind, opts) do
      entry = %{ref: row.ref, kind: spec.kind, field: spec.field, kind_field: spec.kind_field}

      result =
        with :ok <- store(Storage.custodian(owner), row, spec.material),
             do: issue_and_store(owner, rest, opts, [entry | issued], write)

      finish(result, owner, row.ref, opts)
    end
  end

  defp store(custodian, row, material) do
    case AshHooks.Custody.call(custodian, :store, [
           row.ref,
           material,
           row.custody_tenant,
           row.kind
         ]) do
      :ok ->
        :ok

      {:error, reason} = error when reason in [:invalid_material, :ref_destroyed, :unavailable] ->
        AshHooks.Errors.from_custody_result(error)

      _ ->
        AshHooks.Errors.from_custody_result(:invalid_store_result)
    end
  end

  defp retire_replaced(_owner, _persisted, [], _opts), do: :ok

  defp retire_replaced(owner, persisted, [ref | rest], opts) do
    if Transitions.holds_ref?(persisted, ref) do
      retire_replaced(owner, persisted, rest, opts)
    else
      with :ok <- Transitions.retire(owner, ref, Transitions.now(opts), opts),
           do: retire_replaced(owner, persisted, rest, opts)
    end
  end

  defp persisted_owner(owner, [first | _] = issued, tenant) do
    query =
      owner
      |> Storage.owner_query(tenant)
      |> Ash.Query.filter(^Ash.Expr.ref(first.field) == ^first.ref)

    with {:ok, rows} <- Ash.read(query, authorize?: false, tenant: tenant),
         do: validate_owner(rows, issued)
  end

  defp validate_owner([row], issued) do
    if Enum.all?(issued, fn key ->
         Map.get(row, key.field) == key.ref and Map.get(row, key.kind_field) == key.kind
       end),
       do: {:ok, row},
       else: {:error, :owner_mismatch}
  end

  defp validate_owner(_rows, _issued), do: {:error, :owner_mismatch}

  defp attach(owner, issued, opts) do
    Enum.reduce_while(issued, :ok, fn key, :ok ->
      case Transitions.attach(owner, key.ref, opts) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp finish({:error, _} = result, owner, ref, opts),
    do: with(:ok <- Transitions.cleanup(owner, ref, opts), do: result)

  defp finish(result, _owner, _ref, _opts), do: result

  def attributes(issued) do
    Map.new(issued, &{&1.field, &1.ref})
    |> Map.merge(Map.new(issued, &{&1.kind_field, &1.kind}))
  end
end
