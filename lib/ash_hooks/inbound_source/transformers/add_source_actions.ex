defmodule AshHooks.InboundSource.Transformers.AddSourceActions do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Ash.Resource.Builder
  alias Ash.Resource.Change.Builtins
  alias AshHooks.KeyLifecycle.Actions
  alias Spark.Dsl.Transformer
  import Ash.Expr, only: [arg: 1]

  def before?(Ash.Resource.Transformers.DefaultAccept), do: true
  def before?(Ash.Resource.Transformers.SetPrimaryActions), do: true
  def before?(Ash.Resource.Transformers.RequireUniqueActionNames), do: true
  def before?(_), do: false
  def after?(AshHooks.InboundSource.Transformers.AddSourceFields), do: true
  def after?(_), do: false

  def transform(state) do
    fields = %{AshHooks.KeyLifecycle.fields(:standard) | retire: :expire_previous_secret}
    {:ok, read} = Builder.build_action(:read, :read_custody_owner, pagination: false)

    {:ok, replace} =
      Builder.build_action(:update, :set_custody_keys,
        accept: [:secret_ref, :secret_kind, :secret_created_at, :secret_first_used_at]
      )

    {:ok, public_key} =
      Builder.build_action_argument(:public_key, :term, allow_nil?: false, sensitive?: true)

    {:ok, public_kind} = Builder.build_action_argument(:public_key_kind, :term, allow_nil?: false)

    {:ok, register} =
      Builder.build_action(:update, :register_public_key,
        accept: [],
        arguments: [public_key, public_kind],
        changes: [
          Actions.change_attribute(:public_key, arg(:public_key)),
          Actions.change_attribute(:public_key_kind, arg(:public_key_kind))
        ]
      )

    actions =
      [
        Actions.build_roll_secret(fields, true, true),
        Actions.build_schedule_previous_retirement(fields),
        Actions.build_retire_previous_secret(fields, true),
        read,
        replace,
        register,
        switch(:pause, true),
        switch(:unpause, false)
      ] ++ Actions.build_first_used_actions(fields)

    state = Enum.reduce(actions, state, &Transformer.add_entity(&2, [:actions], &1))

    Builder.add_change(state, {AshHooks.Endpoint.Changes.RequireIssuedKeys, source?: true},
      on: [:create, :update]
    )
  end

  defp switch(name, value) do
    {:ok, change} = Builder.build_action_change(Builtins.set_attribute(:paused, value))
    {:ok, action} = Builder.build_action(:update, name, accept: [], changes: [change])
    action
  end
end
