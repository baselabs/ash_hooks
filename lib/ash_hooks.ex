defmodule AshHooks do
  @moduledoc """
  Webhooks for Ash Framework — inbound (receive, verify, dedup → domain events)
  and outbound (sign, deliver, retry, track).

  Attach to a resource:

      use Ash.Resource,
        extensions: [AshHooks]

      webhooks do
        # convention-resolves to AshHooks.Provider.ComplyCube
        inbound :comply_cube do
          secret {:app_env, [:my_app, :complycube_secret]}
          event_id &__MODULE__.extract_event_id/1
        end

        # convention-resolves to AshHooks.Provider.HubSpotV3 — the
        # vendor-default 300s replay window applies; override it either way
        inbound :hub_spot_v3 do
          secret {:app_env, [:my_app, :hubspot_client_secret]}
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
        doc: "The provider name (e.g. `:comply_cube`)."
      ],
      provider: [
        type: :atom,
        doc: """
        The provider MODULE implementing `AshHooks.Provider`. When unset, the
        ingress resolves `AshHooks.Provider.<Camelized(name)>` and fails
        closed when that module does not exist or does not implement the
        behaviour.
        """
      ],
      secret: [
        type: {:custom, AshHooks, :validate_secret_source, []},
        required: true,
        doc: """
        The signing-secret source: an `{M, f, a}` callback, `{:app_env, path}`,
        or a function returning `{:ok, secret} | {:error, :no_webhook_secret}`.
        A literal binary is rejected at parse time (ADR-0005). Scope: this net
        catches the secret passed AS the option value; arguments of an MFA
        source are the consumer's own code.
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
        (e.g. ComplyCube) MUST leave this unset — the verifier rejects a
        window whose provider declares no timestamp header
        (`AshHooks.Provider.timestamp_header/1` returns nil). The window value
        is passed to the provider's `verify_signature/3` in the context map
        for scheme-specific enforcement.
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
    verifiers: [AshHooks.Verifiers.ReplayWindowRequiresTimestamp]

  @doc """
  Schema validator for the `secret` option — accepts only secret SOURCES,
  rejecting a literal binary at DSL parse time (ADR-0005).
  """
  @spec validate_secret_source(term()) :: {:ok, term()} | {:error, String.t()}
  def validate_secret_source({m, f, a} = source)
      when is_atom(m) and is_atom(f) and is_list(a),
      do: {:ok, source}

  def validate_secret_source({:app_env, path} = source) when is_list(path) do
    if path != [] and Enum.all?(path, &is_atom/1) do
      {:ok, source}
    else
      {:error, "invalid {:app_env, path} — path must be a non-empty list of atoms"}
    end
  end

  def validate_secret_source(source) when is_function(source, 0),
    do: {:ok, source}

  def validate_secret_source(source) when is_binary(source),
    do:
      {:error,
       "must be a secret SOURCE — got a literal binary: secrets live in compiled DSL data (ADR-0005); pass {m, f, a}, {:app_env, path}, or a 0-arity function"}

  def validate_secret_source(other),
    do:
      {:error,
       "invalid secret source #{inspect(other)} — pass {m, f, a}, {:app_env, path} (non-empty atoms), or a 0-arity function"}
end
