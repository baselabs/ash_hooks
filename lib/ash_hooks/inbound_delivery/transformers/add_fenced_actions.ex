defmodule AshHooks.InboundDelivery.Transformers.AddFencedActions do
  @moduledoc false
  # Injects the fenced-machine action primitives. The conditional gates do
  # NOT live here — they live in the query filters AshHooks.Ingress builds
  # (WHERE-gated updates are the portable fence; see the extension moduledoc).
  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias Ash.Resource.Change.Builtins
  alias Spark.Dsl.{Extension, Transformer}

  def before?(Ash.Resource.Transformers.DefaultAccept), do: true
  def before?(Ash.Resource.Transformers.CacheActionInputs), do: true
  def before?(Ash.Resource.Transformers.SetPrimaryActions), do: true
  def before?(Ash.Resource.Transformers.RequireUniqueActionNames), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    scope = Extension.get_opt(dsl_state, [:inbound_delivery], :scope_identity, [])

    with {:ok, ingest} <- build_ingest(scope),
         {:ok, claim} <- build_claim(),
         {:ok, mark_processed} <- build_mark_processed(),
         {:ok, mark_failed} <- build_mark_failed(),
         {:ok, renew} <- build_renew(),
         {:ok, redact_payload} <- build_redact_payload(),
         {:ok, prune} <- build_prune() do
      {:ok, dsl_state} = add(dsl_state, :create, ingest)
      {:ok, dsl_state} = add(dsl_state, :update, claim)
      {:ok, dsl_state} = add(dsl_state, :update, mark_processed)
      {:ok, dsl_state} = add(dsl_state, :update, redact_payload)
      {:ok, dsl_state} = add(dsl_state, :destroy, prune)
      {:ok, dsl_state} = add(dsl_state, :update, mark_failed)
      add(dsl_state, :update, renew)
    end
  end

  defp build_prune do
    Builder.build_action(:destroy, :prune, accept: [])
  end

  defp add(dsl_state, _type, entity) do
    {:ok, Transformer.add_entity(dsl_state, [:actions], entity)}
  end

  # No-touch upsert: on conflict nothing is updated — the surviving row is
  # returned, so created/duplicate classification compares ids. Touching
  # observability columns on conflict is the consumer's choice via their own
  # action; the primitive keeps the fence minimal.
  defp build_ingest(scope) do
    Builder.build_action(:create, :ingest,
      upsert?: true,
      upsert_identity: :unique_ingest,
      upsert_fields: [],
      accept: [
        :id,
        :provider,
        :external_event_id,
        :external_event_type,
        :payload,
        :payload_digest | scope
      ]
    )
  end

  defp build_claim do
    import Ash.Expr, only: [expr: 1]

    Builder.build_action(:update, :claim,
      accept: [],
      arguments: [argument(:lease_expires_at, :utc_datetime_usec, allow_nil?: false)],
      changes: [
        change(Builtins.atomic_update(:fencing_token, expr(fencing_token + 1))),
        change(Builtins.atomic_update(:attempts, expr(attempts + 1))),
        change(Builtins.set_attribute(:status, :claimed)),
        change(Builtins.set_attribute(:lease_expires_at, Ash.Expr.arg(:lease_expires_at)))
      ]
    )
  end

  # the retention field-redaction hook: replaces the stored payload
  # under the caller's claim fence (Ingress.redact_payload/4 gates the
  # WHERE; the action itself is a plain primitive, the fence pattern)
  defp build_redact_payload do
    import Ash.Expr, only: [arg: 1]

    {:ok, payload_set} =
      Builder.build_action_change(Builtins.set_attribute(:payload, arg(:payload)))

    {:ok, payload_arg} =
      Builder.build_action_argument(:payload, AshHooks.InboundDelivery.Payload, allow_nil?: false)

    Builder.build_action(:update, :redact_payload,
      accept: [],
      arguments: [payload_arg],
      changes: [payload_set]
    )
  end

  defp build_mark_processed do
    Builder.build_action(:update, :mark_processed,
      accept: [],
      changes: [
        change(Builtins.set_attribute(:status, :processed)),
        change(Builtins.set_attribute(:error_class, nil))
      ]
    )
  end

  defp build_mark_failed do
    import Ash.Expr, only: [expr: 1, arg: 1]

    Builder.build_action(:update, :mark_failed,
      accept: [],
      arguments: [
        argument(:error_class, :string, allow_nil?: false),
        argument(:permanent?, :boolean, allow_nil?: false, default: false)
      ],
      changes: [
        change(
          Builtins.atomic_update(
            :status,
            expr(
              if ^arg(:permanent?) do
                :failed_permanent
              else
                :failed_retryable
              end
            )
          )
        ),
        change(Builtins.set_attribute(:error_class, Ash.Expr.arg(:error_class)))
      ]
    )
  end

  defp build_renew do
    Builder.build_action(:update, :renew,
      accept: [],
      arguments: [argument(:lease_expires_at, :utc_datetime_usec, allow_nil?: false)],
      changes: [
        change(Builtins.set_attribute(:lease_expires_at, Ash.Expr.arg(:lease_expires_at)))
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
