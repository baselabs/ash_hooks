defmodule AshHooks.OutboundDelivery.Transformers.AddSendActions do
  @moduledoc false
  # Injects the send machine's write primitives (the delivery runtime's
  # half of the ledger). Conditional gates do NOT live here — the runtime
  # builds WHERE-gated bulk updates (the portable-fence pattern; the
  # inbound machine's precedent).
  use Spark.Dsl.Transformer

  import Ash.Expr, only: [arg: 1, expr: 1]

  alias Ash.Resource.Builder
  alias Ash.Resource.Change.Builtins
  alias Spark.Dsl.{Extension, Transformer}

  def before?(Ash.Resource.Transformers.DefaultAccept), do: true
  def before?(Ash.Resource.Transformers.CacheActionInputs), do: true
  def before?(Ash.Resource.Transformers.SetPrimaryActions), do: true
  def before?(Ash.Resource.Transformers.RequireUniqueActionNames), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    resend =
      if Extension.get_opt(dsl_state, [:outbound_delivery], :resend_tracking, :off) == :on do
        [build_resend()]
      else
        []
      end

    with {:ok, mark_sending} <- build_mark_sending(),
         {:ok, mark_succeeded} <- build_mark_succeeded(),
         {:ok, mark_send_failed} <- build_mark_send_failed(),
         {:ok, mark_disable_pending} <- build_mark_disable_pending(),
         {:ok, finalize_disable} <- build_finalize_disable(),
         {:ok, dsl_state} <- add(dsl_state, mark_sending),
         {:ok, dsl_state} <- add(dsl_state, mark_succeeded),
         {:ok, dsl_state} <- add(dsl_state, mark_send_failed),
         {:ok, dsl_state} <- add(dsl_state, mark_disable_pending),
         {:ok, dsl_state} <- add_all(dsl_state, resend) do
      add(dsl_state, finalize_disable)
    end
  end

  defp add_all(dsl_state, entities) do
    Enum.reduce_while(entities, {:ok, dsl_state}, fn entity, {:ok, dsl_state} ->
      {:cont, add(dsl_state, entity)}
    end)
  end

  # The resend re-arm (the resend_tracking :on shape): one gated machine
  # write moves a TERMINAL row back to :pending with a fresh retry ladder
  # (resend_baseline freezes the old series), records who asked, and
  # clears the terminal diagnostics. The runtime's WHERE gate (terminal
  # statuses) is the fence; attempts stay monotonic so attempt-history
  # rows stay unique.
  defp build_resend do
    {:ok, count} =
      Builder.build_action_change(Builtins.atomic_update(:resend_count, expr(resend_count + 1)))

    {:ok, baseline} =
      Builder.build_action_change(Builtins.set_attribute(:resend_baseline, arg(:resend_baseline)))

    {:ok, requested_by} =
      Builder.build_action_change(Builtins.set_attribute(:last_resend_by, arg(:requested_by)))

    {:ok, requested_at} =
      Builder.build_action_change(Builtins.set_attribute(:last_resend_at, arg(:requested_at)))

    {:ok, status} = Builder.build_action_change(Builtins.set_attribute(:status, :pending))
    {:ok, error} = Builder.build_action_change(Builtins.set_attribute(:last_error, nil))

    {:ok, next} =
      Builder.build_action_change(Builtins.set_attribute(:next_attempt_at, nil))

    {:ok, code} =
      Builder.build_action_change(Builtins.set_attribute(:response_status, nil))

    {:ok, snippet} =
      Builder.build_action_change(Builtins.set_attribute(:response_snippet, nil))

    {:ok, lease} =
      Builder.build_action_change(Builtins.set_attribute(:send_lease_expires_at, nil))

    {:ok, enqueue_token} =
      Builder.build_action_change(Builtins.set_attribute(:enqueue_token, nil))

    {:ok, enqueue_lease} =
      Builder.build_action_change(Builtins.set_attribute(:enqueue_lease_expires_at, nil))

    changes = [
      status,
      error,
      next,
      code,
      snippet,
      lease,
      enqueue_token,
      enqueue_lease,
      count,
      baseline,
      requested_by,
      requested_at
    ]

    {:ok, action} =
      Builder.build_action(:update, :resend,
        accept: [],
        arguments: [
          argument(:resend_baseline, :integer, allow_nil?: false),
          argument(:requested_by, :string, allow_nil?: false),
          argument(:requested_at, :utc_datetime_usec, allow_nil?: false)
        ],
        changes: changes
      )

    action
  end

  defp add(dsl_state, entity) do
    {:ok, Transformer.add_entity(dsl_state, [:actions], entity)}
  end

  # The attempt row written BEFORE the adapter fires: status flips and the
  # attempt counts in ONE atomic statement (the runtime's WHERE gate is
  # the fence).
  defp build_mark_sending do
    {:ok, bump} =
      Builder.build_action_change(Builtins.atomic_update(:attempts, expr(attempts + 1)))

    {:ok, status} = Builder.build_action_change(Builtins.set_attribute(:status, :sending))

    {:ok, token} =
      Builder.build_action_change(Builtins.set_attribute(:attempt_token, arg(:attempt_token)))

    {:ok, lease} =
      Builder.build_action_change(
        Builtins.set_attribute(:send_lease_expires_at, arg(:send_lease_expires_at))
      )

    Builder.build_action(:update, :mark_sending,
      accept: [],
      arguments: [
        argument(:attempt_token, :uuid, allow_nil?: false),
        argument(:send_lease_expires_at, :utc_datetime_usec, allow_nil?: false)
      ],
      changes: [bump, status, token, lease]
    )
  end

  defp build_mark_succeeded do
    {:ok, status} = Builder.build_action_change(Builtins.set_attribute(:status, :succeeded))

    {:ok, code} =
      Builder.build_action_change(Builtins.set_attribute(:response_status, arg(:response_status)))

    {:ok, snippet} =
      Builder.build_action_change(
        Builtins.set_attribute(:response_snippet, arg(:response_snippet))
      )

    {:ok, clear_lease} =
      Builder.build_action_change(Builtins.set_attribute(:send_lease_expires_at, nil))

    # A terminal outcome RELEASES the enqueue claim: a reconciler whose enqueue
    # raced this worker's completion must find the token gone and no-op its
    # release, never clobber the terminal diagnostic (the 2.0.3 review's
    # stale-replay finding).
    {:ok, clear_enqueue_token} =
      Builder.build_action_change(Builtins.set_attribute(:enqueue_token, nil))

    {:ok, clear_enqueue_lease} =
      Builder.build_action_change(Builtins.set_attribute(:enqueue_lease_expires_at, nil))

    Builder.build_action(:update, :mark_succeeded,
      accept: [],
      arguments: [
        argument(:response_status, :integer, allow_nil?: false),
        argument(:response_snippet, :string, allow_nil?: true)
      ],
      changes: [status, code, snippet, clear_lease, clear_enqueue_token, clear_enqueue_lease]
    )
  end

  # dead_letter? folds the terminal transition into the same gated write —
  # the runtime decides it (ceiling / 4xx / 410 / SSRF / redirect), the
  # fence stays one statement.
  defp build_mark_send_failed do
    {:ok, status} =
      Builder.build_action_change(
        Builtins.atomic_update(
          :status,
          expr(
            if ^arg(:dead_letter?) do
              :dead_letter
            else
              :failed_retryable
            end
          )
        )
      )

    {:ok, error} = Builder.build_action_change(Builtins.set_attribute(:last_error, arg(:error)))

    {:ok, next} =
      Builder.build_action_change(Builtins.set_attribute(:next_attempt_at, arg(:next_attempt_at)))

    # failed rows carry the no-body summary when the attempt saw a
    # response (#17 story 1); pre-send failures persist nils
    {:ok, code} =
      Builder.build_action_change(Builtins.set_attribute(:response_status, arg(:response_status)))

    {:ok, snippet} =
      Builder.build_action_change(
        Builtins.set_attribute(:response_snippet, arg(:response_snippet))
      )

    {:ok, clear_lease} =
      Builder.build_action_change(Builtins.set_attribute(:send_lease_expires_at, nil))

    # A terminal/retry outcome RELEASES the enqueue claim (see mark_succeeded).
    {:ok, clear_enqueue_token} =
      Builder.build_action_change(Builtins.set_attribute(:enqueue_token, nil))

    {:ok, clear_enqueue_lease} =
      Builder.build_action_change(Builtins.set_attribute(:enqueue_lease_expires_at, nil))

    Builder.build_action(:update, :mark_send_failed,
      accept: [],
      arguments: [
        argument(:error, :string, allow_nil?: false),
        argument(:next_attempt_at, :utc_datetime_usec, allow_nil?: true, default: nil),
        argument(:dead_letter?, :boolean, allow_nil?: false, default: false),
        argument(:response_status, :integer, allow_nil?: true, default: nil),
        argument(:response_snippet, :string, allow_nil?: true, default: nil)
      ],
      changes: [
        status,
        error,
        next,
        code,
        snippet,
        clear_lease,
        clear_enqueue_token,
        clear_enqueue_lease
      ]
    )
  end

  defp build_mark_disable_pending do
    Builder.build_action(:update, :mark_disable_pending,
      accept: [],
      arguments: [
        argument(:response_status, :integer, allow_nil?: false),
        argument(:response_snippet, :string, allow_nil?: true),
        argument(:endpoint_snapshot, :map, allow_nil?: false)
      ],
      changes: [
        change(Builtins.set_attribute(:status, :disable_pending)),
        change(Builtins.set_attribute(:response_status, arg(:response_status))),
        change(Builtins.set_attribute(:response_snippet, arg(:response_snippet))),
        change(Builtins.set_attribute(:endpoint_snapshot, arg(:endpoint_snapshot))),
        change(Builtins.set_attribute(:last_error, "gone_410")),
        change(Builtins.set_attribute(:next_attempt_at, nil)),
        change(Builtins.set_attribute(:send_lease_expires_at, nil)),
        # The durable obligation releases the enqueue claim with it: a crash
        # between storage and finalization must leave gone_410 as the standing
        # diagnostic, never restorable-over by a stale reconciler release.
        change(Builtins.set_attribute(:enqueue_token, nil)),
        change(Builtins.set_attribute(:enqueue_lease_expires_at, nil))
      ]
    )
  end

  defp build_finalize_disable do
    Builder.build_action(:update, :finalize_disable,
      accept: [],
      arguments: [argument(:error, :string, allow_nil?: false)],
      changes: [
        change(Builtins.set_attribute(:status, :dead_letter)),
        change(Builtins.set_attribute(:last_error, arg(:error))),
        change(Builtins.set_attribute(:enqueue_token, nil)),
        change(Builtins.set_attribute(:enqueue_lease_expires_at, nil))
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
