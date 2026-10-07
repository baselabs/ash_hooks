defmodule AshHooks.OutboundDelivery.Transformers.AddDeliveryActions do
  @moduledoc false
  # Injects the delivery machine's write primitives. Conditional gates do
  # NOT live here — the dispatcher builds WHERE-gated bulk updates (the
  # portable-fence pattern the inbound machine established: action-level
  # `change filter` is silently dropped on the atomic path).
  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias Ash.Resource.Change.Builtins
  alias Spark.Dsl.{Extension, Transformer}

  def before?(Ash.Resource.Transformers.DefaultAccept), do: true
  def before?(Ash.Resource.Transformers.CacheActionInputs), do: true
  def before?(Ash.Resource.Transformers.SetPrimaryActions), do: true
  def before?(Ash.Resource.Transformers.RequireUniqueActionNames), do: true
  def before?(_), do: false

  # the :dispatch accept list keys off the resource's PK shape (H2) — the
  # fields transformer must have injected (or the consumer declared) it
  # first; Spark's topological order does NOT follow the extension's
  # list order
  def after?(AshHooks.OutboundDelivery.Transformers.AddDeliveryFields), do: true
  def after?(_), do: false

  def transform(dsl_state) do
    payload_attribute =
      Extension.get_opt(dsl_state, [:outbound_delivery], :payload_attribute, :payload)

    prune_action = Extension.get_opt(dsl_state, [:outbound_delivery], :prune_action, :destroy)

    with {:ok, dispatch} <- build_dispatch(payload_attribute, writable_id_pk?(dsl_state)),
         {:ok, mark_enqueue_failed} <- build_mark_enqueue_failed(),
         {:ok, requeue} <- build_requeue(),
         {:ok, bind_dispatch_source} <- build_bind_dispatch_source(),
         {:ok, bind_dispatch_route} <- build_bind_dispatch_route(),
         {:ok, claim_enqueue} <- build_claim_enqueue(),
         {:ok, release_enqueue} <- build_release_enqueue(),
         {:ok, dsl_state} <- add(dsl_state, dispatch),
         {:ok, dsl_state} <- add(dsl_state, mark_enqueue_failed),
         {:ok, dsl_state} <- add(dsl_state, bind_dispatch_source),
         {:ok, dsl_state} <- add(dsl_state, bind_dispatch_route),
         {:ok, dsl_state} <- add(dsl_state, claim_enqueue),
         {:ok, dsl_state} <- add(dsl_state, release_enqueue) do
      # the accept-list decision is PERSISTED for the runtime (H2): the
      # Dispatcher reads the SAME answer, never a re-derived predicate
      # that could disagree with the compiled action (composite PKs and
      # non-:id PKs make naive ":id exists and is writable" diverge)
      dsl_state = Transformer.persist(dsl_state, :id_accepted?, writable_id_pk?(dsl_state))

      add_rest(dsl_state, prune_action, requeue)
    end
  end

  # :none = the append-only ledger opt-out: NO destroy action exists on
  # the resource (an arch pin refusing :destroy stays green), and the
  # prune hook fails loud at runtime
  defp add_rest(dsl_state, :none, requeue), do: add(dsl_state, requeue)

  defp add_rest(dsl_state, _destroy, requeue) do
    with {:ok, prune} <- build_prune(),
         {:ok, dsl_state} <- add(dsl_state, prune) do
      add(dsl_state, requeue)
    end
  end

  defp build_prune do
    Builder.build_action(:destroy, :prune, accept: [])
  end

  defp add(dsl_state, entity) do
    {:ok, Transformer.add_entity(dsl_state, [:actions], entity)}
  end

  # No-touch upsert: on conflict nothing is updated — the surviving row is
  # returned, so created/duplicate classification compares ids (when the
  # PK is writable; otherwise the Dispatcher pre-reads the identity — H2).
  # Retrying deliveries mutate rows only through the runtime's gated
  # updates.
  defp build_dispatch(payload_attribute, id_accepted) do
    Builder.build_action(:create, :dispatch,
      upsert?: true,
      upsert_identity: :unique_delivery,
      upsert_fields: [],
      accept:
        maybe_accept_id(id_accepted, [
          :event_uuid,
          :event_type,
          payload_attribute,
          :endpoint_id,
          :subscription_id,
          :signing_mode,
          :dispatch_source,
          :dispatch_route
        ])
    )
  end

  # H2: `:id` rides the accept list exactly when the resource HAS a
  # writable `:id` attribute — the shapes that always worked (the
  # package-injected PK; a consumer's writable `:id` beside a differently
  # named PK) keep it, and only the shapes Ash's ValidateAccept rejects
  # (uuid_v7_primary_key & other non-writable ids) drop it.
  defp writable_id_pk?(dsl_state) do
    case dsl_state |> Transformer.get_entities([:attributes]) |> Enum.find(&(&1.name == :id)) do
      %{writable?: true} -> true
      _ -> false
    end
  end

  defp maybe_accept_id(true, accept), do: [:id | accept]
  defp maybe_accept_id(false, accept), do: accept

  defp build_mark_enqueue_failed do
    Builder.build_action(:update, :mark_enqueue_failed,
      accept: [],
      arguments: [argument(:error, :string, allow_nil?: false)],
      changes: [
        change(Builtins.set_attribute(:status, :enqueue_failed)),
        change(Builtins.set_attribute(:last_error, Ash.Expr.arg(:error))),
        change(Builtins.set_attribute(:enqueue_token, nil)),
        change(Builtins.set_attribute(:enqueue_lease_expires_at, nil))
      ]
    )
  end

  defp build_bind_dispatch_route do
    Builder.build_action(:update, :bind_dispatch_route,
      accept: [],
      arguments: [argument(:dispatch_route, :string, allow_nil?: false)],
      changes: [change(Builtins.set_attribute(:dispatch_route, Ash.Expr.arg(:dispatch_route)))]
    )
  end

  defp build_bind_dispatch_source do
    Builder.build_action(:update, :bind_dispatch_source,
      accept: [],
      arguments: [argument(:dispatch_source, :string, allow_nil?: false)],
      changes: [change(Builtins.set_attribute(:dispatch_source, Ash.Expr.arg(:dispatch_source)))]
    )
  end

  defp build_claim_enqueue do
    Builder.build_action(:update, :claim_enqueue,
      accept: [],
      arguments: [
        argument(:enqueue_token, :uuid, allow_nil?: false),
        argument(:enqueue_lease_expires_at, :utc_datetime_usec, allow_nil?: false)
      ],
      changes: [
        change(Builtins.set_attribute(:enqueue_token, Ash.Expr.arg(:enqueue_token))),
        change(
          Builtins.set_attribute(
            :enqueue_lease_expires_at,
            Ash.Expr.arg(:enqueue_lease_expires_at)
          )
        )
      ]
    )
  end

  defp build_release_enqueue do
    Builder.build_action(:update, :release_enqueue,
      accept: [],
      arguments: [argument(:error, :string, allow_nil?: true, default: nil)],
      changes: [
        change(Builtins.set_attribute(:enqueue_token, nil)),
        change(Builtins.set_attribute(:enqueue_lease_expires_at, nil)),
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
