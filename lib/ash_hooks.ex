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
        type: {:custom, AshHooks, :validate_secret_source, []},
        required: true,
        doc: """
        The signing-secret source: an `{M, f, a}` callback, `{:app_env, path}`,
        or a function returning `{:ok, secret} | {:error, :no_webhook_secret}`.
        Literal binaries are rejected at parse time (and again by
        `AshHooks.Verifiers.NoLiteralSecrets`) — secrets never live in DSL
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
        (e.g. ComplyCube) MUST leave this unset — the provider registry
        verifier rejects a window whose provider declares no timestamp source
        (lands with the provider registry; the inbound slice's acceptance
        cites this rule).
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
    verifiers: [AshHooks.Verifiers.NoLiteralSecrets]

  @doc """
  Schema validator for the `secret` option — accepts only secret SOURCES.
  Runs at DSL parse time (synchronously), with the verifier as a second net.
  """
  @spec validate_secret_source(term()) :: {:ok, term()} | {:error, String.t()}
  def validate_secret_source({m, f, a} = source)
      when is_atom(m) and is_atom(f) and is_list(a),
      do: {:ok, source}

  def validate_secret_source({:app_env, path} = source) when is_list(path),
    do: {:ok, source}

  def validate_secret_source(source) when is_function(source, 0),
    do: {:ok, source}

  def validate_secret_source(source) when is_binary(source),
    do: {:error, "must be a secret SOURCE — got a literal binary: secrets live in compiled DSL data (ADR-0005); pass {m, f, a}, {:app_env, path}, or a 0-arity function"}

  def validate_secret_source(other),
    do: {:error, "invalid secret source #{inspect(other)} — pass {m, f, a}, {:app_env, path}, or a 0-arity function"}
end
