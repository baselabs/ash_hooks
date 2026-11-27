defmodule AshHooks.Subscription.Changes.CheckHostFilters do
  @moduledoc false
  use Ash.Resource.Change

  alias AshHooks.Subscription

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      with {:ok, filters} <- Ash.Changeset.fetch_change(changeset, :event_filters),
           {:error, error} <- Subscription.validate_filters(changeset.resource, filters) do
        Ash.Changeset.add_error(changeset, error)
      else
        _ -> changeset
      end
    end)
  end

  @impl true
  def atomic(changeset, _opts, _context), do: {:ok, changeset}

  @impl true
  def temporal_safe?(_opts), do: true
end
