defmodule AshHooks.KeyLifecycle.Actions do
  @moduledoc false
  import Ash.Expr, only: [arg: 1]
  alias Ash.Resource.Builder
  alias Ash.Resource.Change.Builtins

  def build_roll_secret(fields, custody?, empty_current? \\ false) do
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
          change_attribute(fields.kind, arg(:new_kind))
        ],
        else: []

    changes =
      [prev_ref, ref, created, first_used, prev_created, prev_first_used, prev_retired] ++
        kind_changes

    kind_arguments =
      if custody?,
        do: [
          argument(:old_kind, :term, allow_nil?: true),
          argument(:new_kind, :term, allow_nil?: true)
        ],
        else: []

    {:ok, action} =
      Builder.build_action(:update, fields.roll,
        accept: [],
        arguments:
          [
            argument(:new_secret_ref, AshHooks.Endpoint.SecretRef,
              allow_nil?: false,
              sensitive?: true
            ),
            argument(:old_ref, AshHooks.Endpoint.SecretRef,
              sensitive?: true,
              allow_nil?: fields.option == :legacy_key_lifecycle or empty_current?
            ),
            argument(:old_created_at, :utc_datetime_usec, allow_nil?: true, default: nil),
            argument(:retired_at, :utc_datetime_usec,
              allow_nil?: fields.option == :legacy_key_lifecycle or empty_current?
            ),
            argument(:rolled_at, :utc_datetime_usec, allow_nil?: false)
          ] ++ kind_arguments,
        changes: changes
      )

    action
  end

  def build_schedule_previous_retirement(fields) do
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

  def build_retire_previous_secret(fields, custody?) do
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

  def build_first_used_actions(fields) do
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

  def change_attribute(name, value) do
    {:ok, change} = Builder.build_action_change(Builtins.set_attribute(name, value))
    change
  end

  defp argument(name, type, opts) do
    {:ok, entity} = Builder.build_action_argument(name, type, opts)
    entity
  end
end
