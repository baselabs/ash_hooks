defmodule AshHooks.OutboundDelivery do
  @moduledoc """
  Turns the consumer's resource into the outbound delivery ledger: a durable,
  deduplicated obligation recording that an event must be delivered to an
  endpoint (the outbound twin of `AshHooks.InboundDelivery`). Sends remain
  at-least-once, and receivers deduplicate retries by webhook id.

      use Ash.Resource,
        data_layer: AshSqlite.DataLayer,
        extensions: [AshHooks.OutboundDelivery]

      # optional: rename the exact-bytes column when `payload` is
      # reserved by the consumer's domain (e.g. a sole payload store)
      outbound_delivery do
        payload_attribute :event_bytes
      end

  The extension injects the delivery fields (`event_uuid` — the webhook
  id, immutable across retries; the exact `payload` bytes to sign;
  `endpoint_id`/`subscription_id`; immutable `dispatch_source` and
  `dispatch_route`; the lifecycle `status`; accounting `attempts`; fenced
  send and enqueue tokens/leases; the durable 410 endpoint snapshot;
  the machine-written `response_status`/`response_snippet`/
  `next_attempt_at`; bounded `last_error`), the `unique_delivery`
  identity on `[:endpoint_id, :event_uuid]`. The ownership fields default to
  explicit direct/unbound markers so existing direct callers of `:dispatch`
  remain valid; the first authorized direct driver and worker route bind them
  once with compare-and-set updates. Host declarations that replace these
  fields with incompatible types, nullability, defaults, or writable machine
  fields fail resource verification. Oban admission includes this
  receiver identity plus the complete row key, source, route, and tenant.
  The extension also injects the machine primitives `:dispatch` (no-touch unique upsert, the
  `:ingest` mirror) and `:mark_enqueue_failed`.

  Storage-level uniqueness on `unique_delivery` is the idempotency
  primitive: the consumer's migration must carry the matching unique
  index (ADR-0003's argument, applied outbound).

  `response_status`, `response_snippet` (the no-body summary by default —
  status + allowlisted content-type token; the `[captured]`-marked,
  redacted body only on the runtime's per-call opt-in), and `next_attempt_at`
  are `writable?: false` — no consumer create/update input accepts them;
  they reach the ledger only
  as arguments of the runtime's machine primitives (`:mark_succeeded`,
  `:mark_send_failed`), fenced to the current attempt. Request and response
  headers are not stored on this resource.

  Rows contain the exact payload bytes you dispatched. Define read policies
  in your domain; the extension does not inject them.

  Policy obligation: the package injects write actions; your application
  defines their authorization.
  Under a permissive base policy fragment (an authorize-if-active-member
  fallback), every actor could otherwise reach the machine primitives —
  mark a delivery succeeded (suppressing a real send), dead-letter one,
  requeue, or prune the ledger. The injected write actions on this
  resource: `:dispatch`, `:mark_enqueue_failed`, `:bind_dispatch_source`,
  `:bind_dispatch_route`, `:claim_enqueue`, `:release_enqueue`, `:requeue`, `:prune`
  (the retention destroy — omittable via `prune_action :none`),
  `:mark_sending`, `:mark_succeeded`, `:mark_send_failed`,
  `:mark_disable_pending`, `:finalize_disable`. Cover each
  with an action-specific policy (the runtime's internal calls run
  `authorize?: false` and never consult them), or ensure no actor-facing
  surface (json_api/graphql/code_interface/admin) exposes the resource.
  The runtime writes through these actions — a policy per action is
  the complete seam.
  """

  @statuses [
    :pending,
    :enqueue_failed,
    :sending,
    :disable_pending,
    :succeeded,
    :failed_retryable,
    :dead_letter
  ]

  @doc """
  The delivery state machine's statuses, in lifecycle order.
  """
  @spec statuses() :: list(atom())
  def statuses, do: @statuses

  @payload_attribute %Spark.Dsl.Section{
    name: :outbound_delivery,
    describe: """
    Configuration of this resource as the outbound delivery ledger.
    """,
    schema: [
      payload_attribute: [
        type: :atom,
        default: :payload,
        doc: """
        The attribute name for the exact payload bytes the dispatcher
        persists and the delivery runtime signs and sends (default
        `:payload`). Rename it when the consumer's domain reserves
        `payload` for its own sole payload store: the injected column,
        the `:dispatch` accept list, and every signing/sending read
        follow the configured name. Must not collide with another
        injected delivery field (fail-closed at compile).
        """
      ],
      prune_action: [
        type: {:in, [:destroy, :none]},
        default: :destroy,
        doc: """
        Whether the retention `destroy :prune` action is injected
        (default `:destroy`). Set `:none` on an append-only audit ledger
        — no destroy action exists on the resource at all, and
        `AshHooks.Delivery.prune/2` fails loud with a named error:
        deletion is then the consumer's own surface.
        """
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@payload_attribute],
    transformers: [
      AshHooks.OutboundDelivery.Transformers.AddDeliveryFields,
      AshHooks.OutboundDelivery.Transformers.AddDeliveryIdentity,
      AshHooks.OutboundDelivery.Transformers.AddDeliveryActions,
      AshHooks.OutboundDelivery.Transformers.AddSendActions
    ],
    verifiers: [
      AshHooks.Verifiers.MultitenancyNoBypass,
      AshHooks.Verifiers.OutboundDeliveryFields
    ]
end
