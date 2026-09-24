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
          # optional: extract a stable event id (payload -> {:ok, id} | :error);
          # without it a deterministic content-hash identity is used
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

  Multi-tenant? Declare Ash attribute multitenancy on the four resources
  (subscription, endpoint, both ledgers) and pass `:tenant` /
  `ctx[:tenant]` to every entry point — every query, write, dedup
  identity, sweep, and job arg is tenant-scoped, and a tenant-less call
  against a multitenant resource fails closed with
  `{:error, :tenant_required}` before any data access. Single-tenant
  apps change nothing. The
  [adoption checklist](https://github.com/baselabs/ash_hooks/blob/main/documentation/tutorials/tenancy-adoption-checklist.md)
  walks the ordered transition (ADR-0011).
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
        a 0-arity function (app-global), or a 1-arity function
        (`tenant -> {:ok, secret} | {:error, :no_webhook_secret}` — resolves
        the TENANT's secret on multitenant ledgers; arity dispatch on literal
        fns is unambiguous). A literal binary is rejected at parse time
        (ADR-0005). Scope: this net catches the secret passed AS the option
        value; arguments of an MFA source are the consumer's own code.
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
      subscriptions: [
        type: :atom,
        doc: """
        The consumer's Subscription resource module (carrying
        `AshHooks.Subscription`) this event fans out through — the
        dispatcher matches its rows against the event type.
        """
      ],
      deliveries: [
        type: :atom,
        doc: """
        The consumer's OutboundDelivery resource module (carrying
        `AshHooks.OutboundDelivery`) the dispatcher writes the durable
        per-endpoint rows into.
        """
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

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshHooks.{Delivery, InboundDelivery, Ingress, OutboundDelivery}
  alias AshHooks.Errors.Unknown.UnknownError

  @doc """
  Fans an outbound event out to its subscribed endpoints — the outbound
  entry point, delegating to `AshHooks.Dispatcher.dispatch/4` (the
  `AshHooks.Ingress.ingest/4` twin).
  """
  @spec dispatch(module(), atom(), AshHooks.Event.t() | term(), keyword()) ::
          {:ok, [AshHooks.Dispatcher.dispatch_result()]} | {:error, term()}
  defdelegate dispatch(resource, name, event, opts \\ []), to: AshHooks.Dispatcher

  @doc """
  Reconciles outbound delivery rows stranded at `:pending` by a crash
  between the row write and the enqueue — the supported, auditable
  alternative to hand-rolled queries against package internals
  (`AshHooks.Dispatcher.reconcile_pending/3`).
  """
  @spec reconcile_pending(module(), atom(), keyword()) ::
          {:ok, [AshHooks.Dispatcher.dispatch_result()]} | {:error, term()}
  defdelegate reconcile_pending(resource, name, opts \\ []), to: AshHooks.Dispatcher

  @typedoc """
  The per-tenant sweep totals: one result per tenant (error-isolated — one
  tenant's failure never stops the others) plus the sum of the successful
  counts.
  """
  @type sweep_totals :: %{
          results: %{optional(term()) => {:ok, non_neg_integer()} | {:error, term()}},
          total: non_neg_integer()
        }

  @doc """
  Maps `AshHooks.Ingress.reap/2` over `tenants:` SEQUENTIALLY, per-tenant
  error isolation — a tenant-less global reap over a multitenant ledger is
  impossible by construction (each tenant's call carries its own
  pre-flight). Sequential by design: the shared repo pool is the one
  cross-tenant starvation surface, so per-tenant sweeps do not contend.

      {:ok, %{results: %{"org_a" => {:ok, 3}, "org_b" => {:ok, 0}}, total: 3}} =
        AshHooks.reap_all(Ledger, tenants: ["org_a", "org_b"])
  """
  @spec reap_all(module(), keyword()) :: {:ok, sweep_totals()}
  def reap_all(resource, opts) do
    sweep(Keyword.fetch!(opts, :tenants), fn tenant ->
      AshHooks.Ingress.reap(resource, Keyword.put(opts, :tenant, tenant))
    end)
  end

  @doc """
  Maps the retention prune over `tenants:` sequentially (routing by the
  resource's extension: inbound ledgers through `AshHooks.Ingress.prune/2`,
  outbound deliveries through `AshHooks.Delivery.prune/2`) — the same
  per-tenant isolation and sequencing as `reap_all/2`.

      {:ok, %{results: %{"org_a" => {:ok, 2}}, total: 2}} =
        AshHooks.prune_all(Delivery, older_than: cutoff, tenants: ["org_a"])
  """
  @spec prune_all(module(), keyword()) :: {:ok, sweep_totals()} | {:error, term()}
  def prune_all(resource, opts) do
    with {:ok, prune} <- prune_route(resource) do
      sweep(Keyword.fetch!(opts, :tenants), fn tenant ->
        prune.(resource, Keyword.put(opts, :tenant, tenant))
      end)
    end
  end

  defp prune_route(resource) do
    extensions = ResourceInfo.extensions(resource)

    cond do
      InboundDelivery in extensions ->
        {:ok, &Ingress.prune/2}

      OutboundDelivery in extensions ->
        {:ok, &Delivery.prune/2}

      true ->
        {:error, unrouteable_resource_error(resource)}
    end
  end

  defp unrouteable_resource_error(resource) do
    UnknownError.exception(
      error:
        inspect(resource) <>
          " carries neither AshHooks.InboundDelivery nor AshHooks.OutboundDelivery — " <>
          "prune_all routes only the package's ledgers"
    )
  end

  # The sweep runs SEQUENTIALLY (D6: pool starvation favors sequential
  # per-tenant sweeps) and never stops on a tenant's error — an {:error, _}
  # tuple OR a crash in one tenant's sweep is carried as that tenant's
  # result (the poison-row precedent: one bad tenant must never starve the
  # rows behind it). The swept calls are the package's own reap/prune;
  # their CONSUMER callbacks (a provider's handle_event) are contained
  # inside Ingress's own safe_redrive rescue+catch, and every remaining
  # crash mode surfaces as a raise in Elixir-land (incl. DBConnection's
  # checkout/ownership errors) — so the sweep-level containment is a
  # rescue.
  defp sweep(tenants, call) do
    # a repeated tenant would overwrite its own earlier result while
    # still counting into the total — deduplicated
    {results, total} =
      Enum.reduce(Enum.uniq(tenants), {%{}, 0}, fn tenant, {results, total} ->
        case safe_call(call, tenant) do
          {:ok, count} -> {Map.put(results, tenant, {:ok, count}), total + count}
          {:error, reason} -> {Map.put(results, tenant, {:error, reason}), total}
        end
      end)

    {:ok, %{results: results, total: total}}
  end

  defp safe_call(call, tenant) do
    call.(tenant)
  rescue
    reason -> {:error, {:sweep_crashed, reason}}
  end

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

  # the 1-arity fn is the TENANT-aware source (ingest resolves it with the
  # ctx tenant); arity dispatch on literal fns is unambiguous
  def validate_secret_source(source) when is_function(source, 0),
    do: {:ok, source}

  def validate_secret_source(source) when is_function(source, 1),
    do: {:ok, source}

  def validate_secret_source(source) when is_binary(source),
    do:
      {:error,
       "must be a secret SOURCE — got a literal binary: secrets live in compiled DSL data (ADR-0005); pass {m, f, a}, {:app_env, path}, or a 0-arity function"}

  def validate_secret_source(other),
    do:
      {:error,
       "invalid secret source #{inspect(other)} — pass {m, f, a}, {:app_env, path} (non-empty atoms), or a 0/1-arity function"}
end
