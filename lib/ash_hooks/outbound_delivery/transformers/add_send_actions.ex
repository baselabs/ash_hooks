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
  alias Spark.Dsl.Transformer

  def before?(Ash.Resource.Transformers.DefaultAccept), do: true
  def before?(Ash.Resource.Transformers.CacheActionInputs), do: true
  def before?(Ash.Resource.Transformers.SetPrimaryActions), do: true
  def before?(Ash.Resource.Transformers.RequireUniqueActionNames), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    with {:ok, mark_sending} <- build_mark_sending(),
         {:ok, mark_succeeded} <- build_mark_succeeded(),
         {:ok, mark_send_failed} <- build_mark_send_failed(),
         {:ok, dsl_state} <- add(dsl_state, mark_sending),
         {:ok, dsl_state} <- add(dsl_state, mark_succeeded) do
      add(dsl_state, mark_send_failed)
    end
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

    Builder.build_action(:update, :mark_sending, accept: [], changes: [bump, status])
  end

  defp build_mark_succeeded do
    {:ok, status} = Builder.build_action_change(Builtins.set_attribute(:status, :succeeded))

    {:ok, code} =
      Builder.build_action_change(Builtins.set_attribute(:response_status, arg(:response_status)))

    {:ok, snippet} =
      Builder.build_action_change(
        Builtins.set_attribute(:response_snippet, arg(:response_snippet))
      )

    Builder.build_action(:update, :mark_succeeded,
      accept: [],
      arguments: [
        argument(:response_status, :integer, allow_nil?: false),
        argument(:response_snippet, :string, allow_nil?: true)
      ],
      changes: [status, code, snippet]
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

    Builder.build_action(:update, :mark_send_failed,
      accept: [],
      arguments: [
        argument(:error, :string, allow_nil?: false),
        argument(:next_attempt_at, :utc_datetime_usec, allow_nil?: true, default: nil),
        argument(:dead_letter?, :boolean, allow_nil?: false, default: false)
      ],
      changes: [status, error, next]
    )
  end

  defp argument(name, type, opts) do
    {:ok, entity} = Builder.build_action_argument(name, type, opts)
    entity
  end
end
