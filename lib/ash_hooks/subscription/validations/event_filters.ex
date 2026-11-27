defmodule AshHooks.Subscription.Validations.EventFilters do
  @moduledoc false
  use Ash.Resource.Validation

  alias AshHooks.Subscription

  @impl true
  def validate(changeset, _opts, _context) do
    with :ok <- validate_input(changeset),
         :ok <- validate_fields(changeset, changeset.attributes),
         :ok <- validate_fields(changeset, changeset.create_atomics) do
      validate_fields(changeset, changeset.atomics)
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: validate(changeset, opts, context)

  @impl true
  def temporal_safe?(_opts), do: true

  # Ash's map caster accepts JSON strings. Check the submitted value as well as
  # the cast value, keeping the same input contract as the import check.
  defp validate_input(changeset) do
    action = changeset.action

    if :event_filters in action.accept and
         not Enum.any?(action.arguments, &(&1.name == :event_filters)) do
      with :ok <- validate_fields(changeset, changeset.params) do
        Subscription.validate_filters(changeset.resource, changeset.params["event_filters"])
      end
    else
      :ok
    end
  end

  defp validate_fields(changeset, fields) do
    Subscription.validate_filters(changeset.resource, fields[:event_filters])
  end
end
