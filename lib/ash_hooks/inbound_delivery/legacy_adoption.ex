defmodule AshHooks.InboundDelivery.LegacyAdoption do
  @moduledoc """
  Plans and applies adoption of provider-defined inbound identities.

  This is an explicit upgrade operation for rows created by the former raw
  body digest default. It never changes declarations with a host `event_id`
  extractor, never guesses an identity for an unavailable payload, and never
  processes a delivery. The caller must quiesce ingress and reapers before
  applying the reviewed plan.
  """

  require Ash.Query

  alias AshHooks.{Info, PrimaryKey, Provider, Tenancy}
  alias Spark.Dsl.Extension

  @recoverable [:received, :claimed, :failed_retryable]
  @superseded_error "legacy_identity_superseded"

  @type audit_row :: %{
          before_key: map(),
          after_key: map(),
          before_external_event_id: String.t(),
          after_external_event_id: String.t(),
          before_status: atom(),
          after_status: atom(),
          payload_digest: String.t(),
          canonical_event_id: String.t(),
          representative: boolean(),
          representative_key: map()
        }

  @type plan :: %{
          provider: atom(),
          scope: map(),
          tenant: term(),
          groups: [map()],
          audit: [audit_row()],
          unresolved: [map()],
          conflicts: [map()]
        }

  @doc """
  Builds a payload-free audit plan without changing any row.

  Pass the declaration's exact `:scope` map and, for attribute-multitenant
  ledgers, `:tenant`. `:canonical_ids` may map a legacy external event ID to
  an explicitly recovered canonical ID for a missing or redacted payload.
  The result lists every proposed before/after key, identity, status, selected
  representative, unresolved row, and target conflict.
  """
  @spec plan(module(), atom(), keyword()) :: {:ok, plan()} | {:error, term()}
  def plan(resource, name, opts \\ []) do
    with {:ok, tenant} <- Tenancy.resolve([resource], opts[:tenant]),
         {:ok, inbound} <- fetch_legacy_inbound(resource, name),
         {:ok, provider} <- resolve_provider(inbound, name),
         {:ok, scope} <- normalize_scope(resource, opts[:scope] || %{}),
         :ok <- require_inserted_at(resource),
         {:ok, rows} <- read_partition(resource, name, scope, tenant) do
      canonical_ids = Map.new(opts[:canonical_ids] || %{})
      build_plan(rows, provider, name, scope, tenant, canonical_ids)
    end
  end

  @doc """
  Applies a reviewed adoption transaction for one provider/scope/tenant partition.

  `quiesced?: true` is mandatory. Any unresolved payload or canonical target
  conflict blocks the entire transaction. The resource data layer must support
  transactions; otherwise this returns `{:error, :transactions_not_supported}`
  before applying the plan. Each sibling remains stored with its original
  payload and digest but becomes terminal `:superseded`; the chosen representative
  receives the canonical provider identity and keeps its prior processing class.
  Use the same `:scope`, `:tenant`, and `:canonical_ids` reviewed through `plan/3`.
  """
  @spec apply(module(), atom(), keyword()) :: {:ok, plan()} | {:error, term()}
  def apply(resource, name, opts \\ []) do
    with :ok <- require_quiesced(opts),
         :ok <- require_transactions(resource),
         {:ok, %{unresolved: [], conflicts: []} = plan} <- plan(resource, name, opts),
         {:ok, {:ok, applied}} <-
           Ash.transact(
             resource,
             fn -> apply_groups_transactionally(resource, plan.groups, plan.tenant) end,
             tenant: plan.tenant
           ) do
      {:ok, %{plan | groups: applied.groups, audit: applied.audit}}
    else
      {:ok, %{unresolved: unresolved}} when unresolved != [] ->
        {:error, %{reason: :unresolved_payloads, unresolved: unresolved}}

      {:ok, %{conflicts: conflicts}} when conflicts != [] ->
        {:error, %{reason: :canonical_identity_conflicts, conflicts: conflicts}}

      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_legacy_inbound(resource, name) do
    case Info.inbound(resource, name) do
      nil ->
        {:error, :inbound_not_found}

      %{event_id: extractor} when is_function(extractor, 1) ->
        {:error, :custom_event_id_unchanged}

      inbound ->
        {:ok, inbound}
    end
  end

  defp resolve_provider(inbound, name) do
    provider =
      inbound.provider || Module.concat(AshHooks.Provider, Macro.camelize(to_string(name)))

    if Code.ensure_loaded?(provider) and function_exported?(provider, :event_identity, 1) do
      {:ok, provider}
    else
      {:error, :provider_identity_not_supported}
    end
  end

  defp normalize_scope(resource, input) when is_map(input) do
    declared = Extension.get_opt(resource, [:inbound_delivery], :scope_identity, [])
    known = MapSet.new(declared, &Atom.to_string/1)

    unknown =
      input
      |> Map.keys()
      |> Enum.reject(&(is_atom(&1) or is_binary(&1)))
      |> Enum.concat(
        Enum.reject(Map.keys(input), fn key ->
          (is_atom(key) or is_binary(key)) and MapSet.member?(known, to_string(key))
        end)
      )

    missing =
      Enum.reject(declared, fn name ->
        Map.has_key?(input, name) or Map.has_key?(input, Atom.to_string(name))
      end)

    if unknown == [] and missing == [] do
      {:ok,
       Map.new(declared, fn name ->
         value = Map.get(input, name, Map.get(input, Atom.to_string(name)))
         {name, value}
       end)}
    else
      {:error, :partition_scope_mismatch}
    end
  end

  defp normalize_scope(_resource, _input), do: {:error, :partition_scope_mismatch}

  defp require_inserted_at(resource) do
    if Ash.Resource.Info.attribute(resource, :inserted_at),
      do: :ok,
      else: {:error, :inserted_at_required}
  end

  defp read_partition(resource, name, scope, tenant) do
    resource
    |> Ash.Query.do_filter([provider: name] ++ Map.to_list(scope))
    |> Ash.read(authorize?: false, tenant: tenant)
  end

  defp build_plan(rows, provider, name, scope, tenant, canonical_ids) do
    {resolved, unresolved} =
      Enum.reduce(rows, {[], []}, fn row, {resolved, unresolved} ->
        case canonical_id(provider, row, canonical_ids) do
          {:ok, id} -> {[{row, id} | resolved], unresolved}
          {:error, reason} -> {resolved, [unresolved_row(row, reason) | unresolved]}
        end
      end)

    groups =
      resolved
      |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {canonical_id, group_rows} -> build_group(canonical_id, group_rows) end)

    conflicts = detect_conflicts(resolved)

    {:ok,
     %{
       provider: name,
       scope: scope,
       tenant: tenant,
       groups: groups,
       audit: Enum.flat_map(groups, & &1.audit),
       unresolved: Enum.sort_by(unresolved, &Jason.encode!(&1.key)),
       conflicts: conflicts
     }}
  end

  defp detect_conflicts(resolved) do
    occupants = Enum.group_by(resolved, fn {row, _canonical_id} -> row.external_event_id end)

    resolved
    |> Enum.flat_map(fn {source, canonical_id} ->
      occupants
      |> Map.get(canonical_id, [])
      |> Enum.reject(fn {_occupied, occupied_next_id} -> occupied_next_id == canonical_id end)
      |> Enum.map(fn {occupied, occupied_next_id} ->
        %{
          canonical_event_id: canonical_id,
          source_key: PrimaryKey.encode(source),
          occupied_key: PrimaryKey.encode(occupied),
          occupied_next_event_id: occupied_next_id
        }
      end)
    end)
    |> Enum.uniq()
    |> Enum.sort_by(fn conflict ->
      {conflict.canonical_event_id, Jason.encode!(conflict.source_key),
       Jason.encode!(conflict.occupied_key)}
    end)
  end

  defp canonical_id(provider, row, canonical_ids) do
    case Provider.event_identity(provider, row.payload) do
      {:ok, id} when is_binary(id) and byte_size(id) > 0 and byte_size(id) <= 255 ->
        {:ok, id}

      _error ->
        case Map.fetch(canonical_ids, row.external_event_id) do
          {:ok, id} when is_binary(id) and byte_size(id) > 0 and byte_size(id) <= 255 ->
            {:ok, id}

          _ ->
            {:error, :canonical_identity_required}
        end
    end
  end

  defp unresolved_row(row, reason) do
    %{key: PrimaryKey.encode(row), external_event_id: row.external_event_id, reason: reason}
  end

  defp build_group(canonical_id, rows) do
    representative = Enum.min_by(rows, &representative_order/1)
    representative_key = PrimaryKey.encode(representative)

    changes =
      Enum.map(rows, fn row ->
        representative? = PrimaryKey.map(row) == PrimaryKey.map(representative)
        next_id = next_external_event_id(row, canonical_id, representative?)
        next_status = if representative?, do: row.status, else: :superseded
        next_error = if representative?, do: row.error_class, else: @superseded_error
        after_key = after_primary_key(row, next_id)

        %{
          before_key: PrimaryKey.encode(row),
          after_key: PrimaryKey.encode(after_key),
          before_external_event_id: row.external_event_id,
          after_external_event_id: next_id,
          before_status: row.status,
          after_status: next_status,
          payload_digest: row.payload_digest,
          canonical_event_id: canonical_id,
          representative: representative?,
          representative_key: representative_key,
          external_event_id: row.external_event_id,
          next_external_event_id: next_id,
          next_error_class: next_error
        }
      end)

    %{
      canonical_event_id: canonical_id,
      representative_key: representative_key,
      changes: changes,
      audit:
        Enum.map(
          changes,
          &Map.drop(&1, [:external_event_id, :next_external_event_id, :next_error_class])
        )
    }
  end

  defp representative_order(row) do
    rank =
      cond do
        row.status == :processed -> 0
        row.status in @recoverable -> 1
        row.status == :failed_permanent -> 2
        true -> 3
      end

    {rank, row.inserted_at, Jason.encode!(PrimaryKey.encode(row))}
  end

  defp next_external_event_id(_row, canonical_id, true), do: canonical_id

  defp next_external_event_id(%{external_event_id: canonical_id} = row, canonical_id, false) do
    if String.starts_with?(row.external_event_id, "superseded:v1:") do
      row.external_event_id
    else
      suffix =
        :crypto.hash(:sha256, row.payload_digest <> Jason.encode!(PrimaryKey.encode(row)))
        |> Base.encode16(case: :lower)

      "superseded:v1:" <> suffix
    end
  end

  defp next_external_event_id(row, _canonical_id, false), do: row.external_event_id

  defp after_primary_key(row, next_external_event_id) do
    key = PrimaryKey.map(row)

    if Map.has_key?(key, :external_event_id) do
      Map.put(key, :external_event_id, next_external_event_id)
    else
      key
    end
  end

  defp require_quiesced(opts) do
    if opts[:quiesced?] == true, do: :ok, else: {:error, :ingress_not_quiesced}
  end

  defp require_transactions(resource) do
    if Ash.DataLayer.can?(:transact, resource),
      do: :ok,
      else: {:error, :transactions_not_supported}
  end

  defp apply_groups_transactionally(resource, groups, tenant) do
    case apply_groups(resource, groups, tenant) do
      {:ok, _applied} = success -> success
      {:error, reason} -> Ash.DataLayer.rollback(resource, reason)
    end
  end

  defp apply_groups(resource, groups, tenant) do
    Enum.reduce_while(groups, {:ok, %{groups: [], audit: []}}, fn group, {:ok, acc} ->
      case apply_group(resource, group, tenant) do
        {:ok, applied_group} ->
          {:cont,
           {:ok,
            %{
              groups: [applied_group | acc.groups],
              audit: Enum.reverse(applied_group.audit, acc.audit)
            }}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, %{groups: Enum.reverse(acc.groups), audit: Enum.reverse(acc.audit)}}
      error -> error
    end
  end

  defp apply_group(resource, group, tenant) do
    {representatives, siblings} = Enum.split_with(group.changes, & &1.representative)

    with {:ok, sibling_audit} <- apply_changes(resource, siblings, tenant),
         {:ok, representative_audit} <- apply_changes(resource, representatives, tenant) do
      {:ok, %{group | audit: sibling_audit ++ representative_audit}}
    end
  end

  defp apply_changes(resource, changes, tenant) do
    Enum.reduce_while(changes, {:ok, []}, fn change, {:ok, audit} ->
      case apply_change(resource, change, tenant) do
        {:ok, applied} -> {:cont, {:ok, [applied | audit]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, audit} -> {:ok, Enum.reverse(audit)}
      error -> error
    end
  end

  defp apply_change(resource, change, tenant) do
    key = decode_audit_key!(resource, change.before_key)

    result =
      resource
      |> Ash.Query.do_filter(key)
      |> Ash.Query.filter(
        external_event_id == ^change.external_event_id and status == ^change.before_status
      )
      |> Ash.bulk_update(
        :adopt_legacy_identity,
        %{
          external_event_id: change.next_external_event_id,
          status: change.after_status,
          error_class: change.next_error_class
        },
        authorize?: false,
        return_records?: true,
        return_errors?: true,
        strategy: [:atomic],
        tenant: tenant
      )

    case result do
      %Ash.BulkResult{status: :success, records: [row]} ->
        {:ok,
         change
         |> Map.drop([:external_event_id, :next_external_event_id, :next_error_class])
         |> Map.put(:after_key, PrimaryKey.encode(row))
         |> Map.put(:after_status, row.status)}

      %Ash.BulkResult{status: :success, records: []} ->
        {:error, :partition_changed}

      %Ash.BulkResult{errors: [error | _]} ->
        {:error, error}
    end
  end

  defp decode_audit_key!(resource, encoded) do
    {:ok, key} = PrimaryKey.decode(resource, encoded)
    key
  end
end
