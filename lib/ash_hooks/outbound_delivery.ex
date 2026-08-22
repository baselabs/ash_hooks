defmodule AshHooks.OutboundDelivery do
  @moduledoc """
  Turns the consumer's resource into the outbound delivery ledger — the
  durable, effect-once record of "this event owes this endpoint a
  delivery" (the outbound twin of `AshHooks.InboundDelivery`).

      use Ash.Resource,
        data_layer: AshSqlite.DataLayer,
        extensions: [AshHooks.OutboundDelivery]

  The extension injects the delivery fields (`event_uuid` — the webhook
  id, immutable across retries; the exact `payload` bytes to sign;
  `endpoint_id`/`subscription_id`; the lifecycle `status`; `attempts`;
  the machine-written `response_status`/`response_snippet`/
  `next_attempt_at`; bounded `last_error`), the `unique_delivery`
  identity on `[:endpoint_id, :event_uuid]` — the SAME pair the Oban job
  uniqueness keys use, so row identity and job identity coincide — and
  the machine primitives `:dispatch` (no-touch unique upsert, the
  `:ingest` mirror) and `:mark_enqueue_failed`.

  Storage-level uniqueness on `unique_delivery` is the idempotency
  primitive: the consumer's migration must carry the matching unique
  index (ADR-0003's argument, applied outbound).

  `response_status`, `response_snippet` (the no-body summary by default —
  status + allowlisted content-type token; the `[captured]`-marked,
  floor-redacted body only on the runtime's per-call opt-in, ADR-0005's
  snippet amendment), and `next_attempt_at` are `writable?: false` — no
  consumer create/update INPUT accepts them; they reach the ledger only
  as arguments of the runtime's machine primitives (`:mark_succeeded`,
  `:mark_send_failed`), gated by WHERE-status fences. NO request or
  response headers are stored on this resource at all: the
  stored-header allowlist floor holds by not persisting headers beyond
  the bounded snippet (ADR-0005).

  READ EXPOSURE: rows carry the exact payload bytes you dispatched.
  The package injects NO read policies — read access is governed ENTIRELY
  by the consumer's own domain policies (README → Security).
  """

  @statuses [
    :pending,
    :enqueue_failed,
    :sending,
    :succeeded,
    :failed_retryable,
    :dead_letter
  ]

  @doc """
  The delivery state machine's statuses, in lifecycle order.
  """
  @spec statuses() :: list(atom())
  def statuses, do: @statuses

  use Spark.Dsl.Extension,
    transformers: [
      AshHooks.OutboundDelivery.Transformers.AddDeliveryFields,
      AshHooks.OutboundDelivery.Transformers.AddDeliveryIdentity,
      AshHooks.OutboundDelivery.Transformers.AddDeliveryActions,
      AshHooks.OutboundDelivery.Transformers.AddSendActions
    ],
    verifiers: []
end
