defmodule AshHooks.OutboundOutbox.Notifier do
  @moduledoc false
  use Ash.Notifier

  @impl true
  def notify(%{action: %{name: :publish}, data: row, changeset: changeset}) do
    unless Ash.DataLayer.in_transaction?(row.__struct__) do
      committed(row, changeset)
    end

    :ok
  end

  def notify(_notification), do: :ok

  defp committed(row, changeset) do
    supplied = Ash.Changeset.get_attribute(changeset, :acceptance_token)
    outcome = if supplied == row.acceptance_token, do: :accepted, else: :duplicate

    keys = [
      :dispatch_source,
      :dispatch_route,
      :event_type,
      :version,
      :payload,
      :metadata,
      :format_version
    ]

    submitted = Map.new(keys, &{&1, Ash.Changeset.get_attribute(changeset, &1)})

    if Map.take(row, keys) === submitted do
      AshHooks.Outbox.emit(:publish, row, outcome, changeset.tenant)
      if outcome == :accepted and row.state == :pending, do: trigger(row, changeset.tenant)
    end

    :ok
  end

  defp trigger(row, tenant) do
    case AshHooks.Outbox.option(row.__struct__, :trigger) do
      nil ->
        :ok

      {module, function} ->
        case apply(module, function, [row, tenant]) do
          :ok -> :ok
          _other -> AshHooks.Outbox.emit(:trigger, row, :failed, tenant, :trigger_failed)
        end
    end
  rescue
    _error -> AshHooks.Outbox.emit(:trigger, row, :failed, tenant, :trigger_failed)
  catch
    _kind, _reason -> AshHooks.Outbox.emit(:trigger, row, :failed, tenant, :trigger_failed)
  end
end
