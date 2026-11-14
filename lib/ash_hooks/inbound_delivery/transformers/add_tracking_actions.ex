defmodule AshHooks.InboundDelivery.Transformers.AddTrackingActions do
  @moduledoc false
  # The ingress_tracking :on machine actions: :count_duplicate (the
  # WHERE-gated duplicates bump on duplicate ingest) and :record_rejection
  # (the payload-less failed-verification row behind Ingress.counts/2).
  use Spark.Dsl.Transformer

  import Ash.Expr, only: [expr: 1]

  alias Ash.Resource.Builder
  alias Ash.Resource.Change.Builtins
  alias AshHooks.InboundDelivery.Transformers.AddFencedActions
  alias Spark.Dsl.{Extension, Transformer}

  def before?(Ash.Resource.Transformers.DefaultAccept), do: true
  def before?(Ash.Resource.Transformers.CacheActionInputs), do: true
  def before?(Ash.Resource.Transformers.SetPrimaryActions), do: true
  def before?(Ash.Resource.Transformers.RequireUniqueActionNames), do: true
  def before?(_), do: false

  # the :record_rejection accept list follows :ingest's id rule, which reads
  # the injected (or declared) `:id` attribute
  def after?(AshHooks.InboundDelivery.Transformers.AddLedgerFields), do: true
  def after?(_), do: false

  def transform(dsl_state) do
    if Extension.get_opt(dsl_state, [:inbound_delivery], :ingress_tracking, :off) == :on do
      with {:ok, count} <- build_count_duplicate(),
           {:ok, reject} <- build_record_rejection(dsl_state) do
        {:ok, dsl_state} = add(dsl_state, count)
        add(dsl_state, reject)
      end
    else
      {:ok, dsl_state}
    end
  end

  defp build_count_duplicate do
    {:ok, bump} =
      Builder.build_action_change(Builtins.atomic_update(:duplicates, expr(duplicates + 1)))

    # unconstrained counter: the atomic bump composes on every supported
    # data layer; the runtime is the only writer
    Builder.build_action(:update, :count_duplicate, accept: [], changes: [bump])
  end

  # The rejection row: the digest-scoped identity, a CONSTANT payload
  # marker (never unverified request bytes), status :failed_verification.
  defp build_record_rejection(dsl_state) do
    {:ok, status} =
      Builder.build_action_change(Builtins.set_attribute(:status, :failed_verification))

    # the scope slots ride the accept list (the dedup identity is scoped)
    scope = Extension.get_opt(dsl_state, [:inbound_delivery], :scope_identity, [])

    # `:id` rides the accept list exactly when `:ingest`'s does (a writable
    # `:id`); a generated key such as uuid_v7_primary_key cannot accept it
    id = if AddFencedActions.writable_id_pk?(dsl_state), do: [:id], else: []

    Builder.build_action(:create, :record_rejection,
      upsert?: true,
      upsert_identity: :unique_ingest,
      upsert_fields: [],
      accept:
        id ++
          [:provider, :external_event_id, :external_event_type, :payload, :payload_digest] ++
          scope,
      changes: [status]
    )
  end

  defp add(dsl_state, entity), do: {:ok, Transformer.add_entity(dsl_state, [:actions], entity)}
end
