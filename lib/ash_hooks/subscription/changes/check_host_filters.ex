defmodule AshHooks.Subscription.Changes.CheckHostFilters do
  @moduledoc false
  use Ash.Resource.Change

  alias AshHooks.Subscription

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case check_attribute(changeset) do
        :ok -> changeset
        {:error, error} -> Ash.Changeset.add_error(changeset, error)
      end
    end)
  end

  @impl true
  def atomic(changeset, _opts, _context) do
    with :ok <- check_attribute(changeset),
         :ok <- check_atomic(changeset) do
      {:ok, changeset}
    end
  end

  @impl true
  def temporal_safe?(_opts), do: true

  defp check_attribute(changeset) do
    case Ash.Changeset.fetch_change(changeset, :event_filters) do
      {:ok, filters} -> Subscription.validate_filters(changeset.resource, filters)
      :error -> :ok
    end
  end

  defp check_atomic(changeset) do
    with {:ok, filters} <- Keyword.fetch(changeset.atomics, :event_filters),
         false <- Ash.Expr.expr?(filters) do
      Subscription.validate_filters(changeset.resource, filters)
    else
      _ -> :ok
    end
  end
end
