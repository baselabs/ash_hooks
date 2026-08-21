defmodule AshHooks do
  @moduledoc """
  Webhooks for Ash Framework — inbound (receive, verify, dedup → domain events)
  and outbound (sign, deliver, retry, track).

  Attach to a resource:

      use Ash.Resource,
        extensions: [AshHooks]

      webhooks do
        inbound :complycube do
          secret {:app_env, [:my_app, :complycube_secret]}
          event_id &__MODULE__.extract_event_id/1
        end

        outbound :order_paid do
          signing_mode :dual
        end
      end

  Both halves are independently consumable: inbound-only consumers pull no
  queue infrastructure (ADR-0004).
  """

  @inbound %Spark.Dsl.Entity{
    name: :inbound,
    args: [:name],
    target: AshHooks.Inbound,
    describe: """
    Declares an inbound webhook source — a provider whose deliveries this
    resource receives, verifies, deduplicates, and handles.
    """,
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The provider name (e.g. `:complycube`)."
      ],
      secret: [
        type: :any,
        required: true,
        doc: """
        The signing-secret source: an `{M, f, a}` callback, `{:app_env, path}`,
        or a function returning `{:ok, secret} | {:error, :no_webhook_secret}`.
        Literal binaries are rejected by a verifier — secrets never live in DSL
        source (ADR-0005).
        """
      ],
      event_id: [
        type: :any,
        doc: """
        Extractor for the provider's external event id from the decoded payload
        (`payload -> {:ok, id} | :error`). Providers without a stable id fall
        back to a deterministic content-hash identity — never a fresh UUID
        (ADR-0003).
        """
      ],
      replay_window_seconds: [
        type: :pos_integer,
        doc: """
        Replay-protection window for providers whose scheme carries a
        trustworthy timestamp (e.g. HubSpot v3). Providers without timestamps
        (e.g. ComplyCube) MUST leave this unset — a verifier rejects a window
        configured for a provider with no timestamp source.
        """
      ]
    ]
  }

  @outbound %Spark.Dsl.Entity{
    name: :outbound,
    args: [:name],
    target: AshHooks.Outbound,
    describe: """
    Declares an outbound webhook event this resource emits to subscribed
    endpoints — signed (Standard Webhooks canon by default) and delivered with
    retry/backoff/dead-letter semantics.
    """,
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The outbound event name (e.g. `:order_paid`)."
      ],
      signing_mode: [
        type: {:in, [:legacy, :dual, :standard]},
        default: :standard,
        doc: """
        Signature envelope: `:standard` (SW canon), `:dual` (SW canon + legacy
        envelope for migrating receivers), `:legacy` (ADR-0002).
        """
      ],
      endpoints: [
        type: {:list, :atom},
        doc: "Subscription/endpoint resource modules this event fans out to."
      ]
    ]
  }

  @webhooks %Spark.Dsl.Section{
    name: :webhooks,
    describe: """
    Webhook declarations — inbound sources and outbound events for this
    resource.
    """,
    entities: [@inbound, @outbound]
  }

  use Spark.Dsl.Extension,
    sections: [@webhooks],
    verifiers: []
end
