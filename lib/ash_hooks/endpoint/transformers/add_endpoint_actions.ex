defmodule AshHooks.Endpoint.Transformers.AddEndpointActions do
  @moduledoc false
  # Injects the durable circuit-breaker transition: `:disable` is the
  # 410 rule's durable endpoint state (ADR-0005 — an in-process fuse
  # forgets; this does not). Consumers flip it through their own surfaces
  # too; the delivery runtime drives it on 410. With `status_attribute`
  # mapped (H4) the same transition writes the CONSUMER's switch.
  use Spark.Dsl.Transformer

  import Ash.Expr, only: [arg: 1]

  alias Ash.Resource.Builder
  alias Ash.Resource.Change.Builtins
  alias Spark.Dsl.{Extension, Transformer}

  def before?(Ash.Resource.Transformers.DefaultAccept), do: true
  def before?(Ash.Resource.Transformers.CacheActionInputs), do: true
  def before?(Ash.Resource.Transformers.SetPrimaryActions), do: true
  def before?(Ash.Resource.Transformers.RequireUniqueActionNames), do: true
  def before?(_), do: false

  # the disable change targets either the injected :status or the
  # consumer-mapped switch — the fields transformer's checks must have
  # run first; Spark's topological order does NOT follow the extension's
  # list order
  def after?(AshHooks.Endpoint.Transformers.AddEndpointFields), do: true
  def after?(_), do: false

  def transform(dsl_state) do
    switch =
      Extension.get_opt(dsl_state, [:endpoint], :status_attribute, nil) || :status

    disabled_value =
      Extension.get_opt(dsl_state, [:endpoint], :disabled_value, :disabled)

    lifecycle =
      for slot <- [:standard, :legacy],
          fields = AshHooks.KeyLifecycle.fields(slot),
          Extension.get_opt(dsl_state, [:endpoint], fields.option, :off) == :on,
          action <- [
            build_roll_secret(
              fields,
              not is_nil(Extension.get_opt(dsl_state, [:endpoint], :custodian))
            ),
            build_schedule_previous_retirement(fields),
            build_retire_previous_secret(
              fields,
              not is_nil(Extension.get_opt(dsl_state, [:endpoint], :custodian))
            )
            | build_first_used_actions(fields)
          ],
          do: action

    # the warned-marker write ships WITH the auto_disable policy that
    # reads it — declaring the policy is declaring the column + action
    warning =
      if Extension.get_opt(dsl_state, [:endpoint, :auto_disable], :failure_share, :__missing__) !=
           :__missing__ do
        [build_mark_disable_warned()]
      else
        []
      end

    custody =
      if Extension.get_opt(dsl_state, [:endpoint], :custodian) do
        {:ok, action} = Builder.build_action(:read, :read_custody_owner, pagination: false)
        [action]
      else
        []
      end

    with {:ok, change} <-
           Builder.build_action_change(Builtins.set_attribute(switch, disabled_value)),
         {:ok, dsl_state} <- add_all(dsl_state, lifecycle ++ warning ++ custody) do
      changes =
        if warning == [],
          do: [change],
          else: [
            change,
            elem(Builder.build_action_change(Builtins.set_attribute(:disable_warned_at, nil)), 1)
          ]

      with {:ok, disable} <-
             Builder.build_action(:update, :disable, accept: [], changes: changes) do
        {:ok, Transformer.add_entity(dsl_state, [:actions], disable)}
      end
    end
  end

  defp build_schedule_previous_retirement(fields) do
    {:ok, retired_at} =
      Builder.build_action_change(Builtins.set_attribute(fields.retired_at, arg(:retired_at)))

    {:ok, action} =
      Builder.build_action(:update, fields.schedule,
        accept: [],
        arguments: [argument(:retired_at, :utc_datetime_usec, allow_nil?: false)],
        changes: [retired_at]
      )

    action
  end

  defp add_all(dsl_state, entities) do
    Enum.reduce_while(entities, {:ok, dsl_state}, fn entity, {:ok, dsl_state} ->
      {:ok, dsl_state} = add(dsl_state, entity)
      {:cont, {:ok, dsl_state}}
    end)
  end

  defp add(dsl_state, entity), do: {:ok, Transformer.add_entity(dsl_state, [:actions], entity)}

  # The roll: the incumbent reference MOVES to previous_secret_ref (the
  # multi-signature seam — both keys sign until the overlap ends), the new
  # reference takes its place, and the old key's lifecycle timeline rides
  # across. The runtime's WHERE gate (same incumbent) fences concurrent
  # rolls; the moving values arrive as ARGUMENTS read off the row (the
  # SecretRef type has no atomic-update expression support).
  defp build_roll_secret(fields, custody?) do
    {:ok, prev_ref} =
      Builder.build_action_change(Builtins.set_attribute(fields.previous_ref, arg(:old_ref)))

    {:ok, ref} =
      Builder.build_action_change(Builtins.set_attribute(fields.ref, arg(:new_secret_ref)))

    {:ok, created} =
      Builder.build_action_change(Builtins.set_attribute(fields.created_at, arg(:rolled_at)))

    {:ok, first_used} =
      Builder.build_action_change(Builtins.set_attribute(fields.first_used_at, nil))

    {:ok, prev_created} =
      Builder.build_action_change(
        Builtins.set_attribute(fields.previous_created_at, arg(:old_created_at))
      )

    {:ok, prev_first_used} =
      Builder.build_action_change(Builtins.set_attribute(fields.previous_first_used_at, nil))

    {:ok, prev_retired} =
      Builder.build_action_change(Builtins.set_attribute(fields.retired_at, arg(:retired_at)))

    kind_changes =
      if custody?,
        do: [
          change_attribute(fields.previous_kind, arg(:old_kind)),
          change_attribute(fields.kind, nil)
        ],
        else: []

    changes =
      [prev_ref, ref, created, first_used, prev_created, prev_first_used, prev_retired] ++
        kind_changes

    kind_arguments = if custody?, do: [argument(:old_kind, :term, allow_nil?: true)], else: []

    {:ok, action} =
      Builder.build_action(:update, fields.roll,
        accept: [],
        arguments:
          [
            argument(:new_secret_ref, AshHooks.Endpoint.SecretRef, allow_nil?: false),
            argument(:old_ref, AshHooks.Endpoint.SecretRef,
              allow_nil?: fields.option == :legacy_key_lifecycle
            ),
            argument(:old_created_at, :utc_datetime_usec, allow_nil?: true, default: nil),
            argument(:retired_at, :utc_datetime_usec,
              allow_nil?: fields.option == :legacy_key_lifecycle
            ),
            argument(:rolled_at, :utc_datetime_usec, allow_nil?: false)
          ] ++ kind_arguments,
        changes: changes
      )

    action
  end

  # The retirement: the old key's reference leaves the row; its timeline
  # (created, retired — first-used if it ever signed) stays as the record
  defp build_retire_previous_secret(fields, custody?) do
    {:ok, prev_ref} =
      Builder.build_action_change(Builtins.set_attribute(fields.previous_ref, nil))

    {:ok, prev_created} =
      Builder.build_action_change(Builtins.set_attribute(fields.previous_created_at, nil))

    {:ok, prev_first_used} =
      Builder.build_action_change(Builtins.set_attribute(fields.previous_first_used_at, nil))

    {:ok, retired_at} =
      Builder.build_action_change(Builtins.set_attribute(fields.retired_at, arg(:retired_at)))

    kind_changes = if custody?, do: [change_attribute(fields.previous_kind, nil)], else: []
    changes = [prev_ref, prev_created, prev_first_used, retired_at] ++ kind_changes

    {:ok, action} =
      Builder.build_action(:update, fields.retire,
        accept: [],
        changes: changes,
        arguments: [
          argument(:retired_at, :utc_datetime_usec,
            allow_nil?: false,
            default: &DateTime.utc_now/0
          )
        ]
      )

    action
  end

  defp change_attribute(name, value) do
    {:ok, change} = Builder.build_action_change(Builtins.set_attribute(name, value))
    change
  end

  # First-use stamps, written by the delivery runtime at signing time.
  # Two actions, one per key slot: the runtime WHERE-gates each on the
  # stamp still being nil and the reference still being the one that
  # signed, so steady-state sends stop writing.
  # The warned-marker machine write: the sweep stamps `disable_warned_at`
  # on its first warning (gated WHERE still nil — concurrent sweeps
  # single-winner) and clears it on disable or recovery (gated on the
  # value the sweep read). The runtime's WHERE gates are the fence, the
  # same portable pattern as every other machine write.
  defp build_mark_disable_warned do
    {:ok, stamp} =
      Builder.build_action_change(Builtins.set_attribute(:disable_warned_at, arg(:warned_at)))

    {:ok, action} =
      Builder.build_action(:update, :mark_disable_warned,
        accept: [],
        arguments: [argument(:warned_at, :utc_datetime_usec, allow_nil?: true, default: nil)],
        changes: [stamp]
      )

    action
  end

  defp build_first_used_actions(fields) do
    for {action_name, attribute} <- [
          {fields.mark_current, fields.first_used_at},
          {fields.mark_previous, fields.previous_first_used_at}
        ] do
      {:ok, stamp} =
        Builder.build_action_change(Builtins.set_attribute(attribute, arg(:used_at)))

      {:ok, action} =
        Builder.build_action(:update, action_name,
          accept: [],
          arguments: [argument(:used_at, :utc_datetime_usec, allow_nil?: false)],
          changes: [stamp]
        )

      action
    end
  end

  defp argument(name, type, opts) do
    {:ok, entity} = Builder.build_action_argument(name, type, opts)
    entity
  end
end
