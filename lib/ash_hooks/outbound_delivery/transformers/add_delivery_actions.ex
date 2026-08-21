defmodule AshHooks.OutboundDelivery.Transformers.AddDeliveryActions do
  @moduledoc false
  # Injects the delivery machine's write primitives. Conditional gates do
  # NOT live here — the dispatcher builds WHERE-gated bulk updates (the
  # portable-fence pattern the inbound machine established: action-level
  # `change filter` is silently dropped on the atomic path).
  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias Ash.Resource.Change.Builtins
  alias Spark.Dsl.Transformer

  def before?(Ash.Resource.Transformers.DefaultAccept), do: true
  def before?(Ash.Resource.Transformers.CacheActionInputs), do: true
  def before?(Ash.Resource.Transformers.SetPrimaryActions), do: true
  def before?(Ash.Resource.Transformers.RequireUniqueActionNames), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    with {:ok, dispatch} <- build_dispatch(),
         {:ok, mark_enqueue_failed} <- build_mark_enqueue_failed(),
         {:ok, requeue} <- build_requeue(),
         {:ok, dsl_state} <- add(dsl_state, dispatch),
         {:ok, dsl_state} <- add(dsl_state, mark_enqueue_failed) do
      add(dsl_state, requeue)
    end
  end

  defp add(dsl_state, entity) do
    {:ok, Transformer.add_entity(dsl_state, [:actions], entity)}
  end

  # No-touch upsert: on conflict nothing is updated — the surviving row is
  # returned, so created/duplicate classification compares ids. Retrying
  # deliveries mutate rows only through the runtime's gated updates.
  defp build_dispatch do
    Builder.build_action(:create, :dispatch,
      upsert?: true,
      upsert_identity: :unique_delivery,
      upsert_fields: [],
      accept: [:id, :event_uuid, :event_type, :payload, :endpoint_id, :subscription_id]
    )
  end

  defp build_mark_enqueue_failed do
    Builder.build_action(:update, :mark_enqueue_failed,
      accept: [],
      arguments: [argument(:error, :string, allow_nil?: false)],
      changes: [
        change(Builtins.set_attribute(:status, :enqueue_failed)),
        change(Builtins.set_attribute(:last_error, Ash.Expr.arg(:error)))
      ]
    )
  end

  # The enqueue-repair claim: the dispatcher gates it WHERE
  # status == :enqueue_failed, so only ONE concurrent re-dispatcher wins
  # the :pending flip and calls the enqueuer (claim-then-enqueue CAS).
  defp build_requeue do
    Builder.build_action(:update, :requeue,
      accept: [],
      changes: [
        change(Builtins.set_attribute(:status, :pending)),
        change(Builtins.set_attribute(:last_error, nil))
      ]
    )
  end

  defp argument(name, type, opts) do
    {:ok, entity} = Builder.build_action_argument(name, type, opts)
    entity
  end

  defp change(ref) do
    {:ok, entity} = Builder.build_action_change(ref)
    entity
  end
end
