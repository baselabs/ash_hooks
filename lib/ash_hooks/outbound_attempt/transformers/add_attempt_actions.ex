defmodule AshHooks.OutboundAttempt.Transformers.AddAttemptActions do
  @moduledoc false
  # Injects the attempt-history machine actions: :record (the runtime's
  # idempotent create — upsert on unique_attempt, no conflict update, the
  # surviving row returned) and :prune (the retention destroy).
  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias Spark.Dsl.Transformer

  def before?(Ash.Resource.Transformers.DefaultAccept), do: true
  def before?(Ash.Resource.Transformers.CacheActionInputs), do: true
  def before?(Ash.Resource.Transformers.SetPrimaryActions), do: true
  def before?(Ash.Resource.Transformers.RequireUniqueActionNames), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    with {:ok, record} <- build_record(),
         {:ok, prune} <- Builder.build_action(:destroy, :prune, accept: []),
         {:ok, dsl_state} <- add(dsl_state, record) do
      add(dsl_state, prune)
    end
  end

  # No-touch upsert: on conflict nothing is updated — the surviving row is
  # returned, so a re-drive of the same attempt records exactly once (the
  # dispatch :ingest/:dispatch mirror). The row id is never caller input:
  # idempotency is the (delivery_pk, attempt) identity, so the accept list
  # carries no :id (a consumer-named primary key compiles unchanged).
  defp build_record do
    Builder.build_action(:create, :record,
      upsert?: true,
      upsert_identity: :unique_attempt,
      upsert_fields: [],
      accept: [
        :delivery_pk,
        :endpoint_id,
        :event_uuid,
        :event_type,
        :attempt,
        :outcome,
        :reason,
        :response_status,
        :response_snippet,
        :response_headers,
        :latency_ms,
        :signing_key_ref,
        :test,
        :attempted_at
      ]
    )
  end

  defp add(dsl_state, entity), do: {:ok, Transformer.add_entity(dsl_state, [:actions], entity)}
end
