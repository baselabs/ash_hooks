defmodule AshHooks.Endpoint.Transformers.AddEndpointActions do
  @moduledoc false
  # Injects the durable circuit-breaker transition: `:disable` is the
  # 410 rule's durable endpoint state (ADR-0005: an in-process fuse
  # forgets; this does not). Consumers flip it through their own surfaces
  # too; the delivery runtime drives it on 410. With `status_attribute`
  # mapped (H4) the same transition writes the CONSUMER's switch.
  use Spark.Dsl.Transformer

  import Ash.Expr, only: [arg: 1]

  alias Ash.Resource.Builder
  alias Ash.Resource.Change.Builtins
  alias AshHooks.KeyLifecycle
  alias AshHooks.KeyLifecycle.Actions
  alias Spark.Dsl.{Extension, Transformer}

  def before?(Ash.Resource.Transformers.DefaultAccept), do: true
  def before?(Ash.Resource.Transformers.CacheActionInputs), do: true
  def before?(Ash.Resource.Transformers.SetPrimaryActions), do: true
  def before?(Ash.Resource.Transformers.RequireUniqueActionNames), do: true
  def before?(_), do: false

  # the disable change targets either the injected :status or the
  # consumer-mapped switch; the fields transformer's checks must have
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
          fields = KeyLifecycle.fields(slot),
          Extension.get_opt(dsl_state, [:endpoint], fields.option, :off) == :on,
          action <- [
            Actions.build_roll_secret(
              fields,
              not is_nil(Extension.get_opt(dsl_state, [:endpoint], :custodian))
            ),
            Actions.build_schedule_previous_retirement(fields),
            Actions.build_retire_previous_secret(
              fields,
              not is_nil(Extension.get_opt(dsl_state, [:endpoint], :custodian))
            )
            | Actions.build_first_used_actions(fields)
          ],
          do: action

    # the warned-marker write ships WITH the auto_disable policy that
    # reads it; declaring the policy is declaring the column + action
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

        attributes =
          Transformer.get_entities(dsl_state, [:attributes])
          |> Enum.map(& &1.name)
          |> Enum.filter(fn name ->
            name in [
              :secret_ref,
              :previous_secret_ref,
              :legacy_secret_ref,
              :legacy_previous_secret_ref,
              :secret_kind,
              :previous_secret_kind,
              :legacy_secret_kind,
              :legacy_previous_secret_kind,
              :secret_created_at,
              :secret_first_used_at,
              :legacy_secret_created_at,
              :legacy_secret_first_used_at
            ]
          end)

        {:ok, replace} = Builder.build_action(:update, :set_custody_keys, accept: attributes)
        [action, replace]
      else
        []
      end

    with {:ok, change} <-
           Builder.build_action_change(Builtins.set_attribute(switch, disabled_value)),
         {:ok, dsl_state} <- add_all(dsl_state, lifecycle ++ warning ++ custody),
         {:ok, dsl_state} <- custody_create_guard(dsl_state) do
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

  defp custody_create_guard(state) do
    if Extension.get_opt(state, [:endpoint], :custodian) do
      resolver? = not is_nil(Extension.get_opt(state, [:endpoint], :secret_resolver))

      Builder.add_change(
        state,
        {AshHooks.Endpoint.Changes.RequireIssuedKeys, byte_resolver?: resolver?},
        on: [:create]
      )
    else
      {:ok, state}
    end
  end

  defp add_all(dsl_state, entities) do
    Enum.reduce_while(entities, {:ok, dsl_state}, fn entity, {:ok, dsl_state} ->
      {:ok, dsl_state} = add(dsl_state, entity)
      {:cont, {:ok, dsl_state}}
    end)
  end

  defp add(dsl_state, entity), do: {:ok, Transformer.add_entity(dsl_state, [:actions], entity)}

  # The warned-marker machine write: the sweep stamps `disable_warned_at`
  # on its first warning (gated WHERE still nil; concurrent sweeps
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

  defp argument(name, type, opts) do
    {:ok, entity} = Builder.build_action_argument(name, type, opts)
    entity
  end
end
