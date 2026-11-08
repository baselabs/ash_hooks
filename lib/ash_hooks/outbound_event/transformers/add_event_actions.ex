defmodule AshHooks.OutboundEvent.Transformers.AddEventActions do
  @moduledoc false
  # Injects the event-log machine actions: :record (the dispatcher's
  # idempotent no-touch upsert) and :prune (the retention destroy).
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

  # No-touch upsert: a re-dispatch of the same event id returns the
  # surviving row — the log records each event exactly once.
  defp build_record do
    Builder.build_action(:create, :record,
      upsert?: true,
      upsert_identity: :unique_event,
      upsert_fields: [],
      accept: [:event_uuid, :event_type, :version, :payload]
    )
  end

  defp add(dsl_state, entity), do: {:ok, Transformer.add_entity(dsl_state, [:actions], entity)}
end
