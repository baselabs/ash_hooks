defmodule AshHooks.OutboundOutbox.Notifier do
  @moduledoc false
  use Ash.Notifier

  @impl true
  def notify(%{action: %{name: :publish}, data: row, changeset: changeset}) do
    supplied = Ash.Changeset.get_attribute(changeset, :acceptance_token)
    outcome = if supplied == row.acceptance_token, do: :accepted, else: :duplicate
    AshHooks.Outbox.emit(:publish, row, outcome)

    if outcome == :accepted and row.state == :pending do
      trigger(row)
    end

    :ok
  end

  def notify(_notification), do: :ok

  defp trigger(row) do
    case AshHooks.Outbox.option(row.__struct__, :trigger) do
      nil -> :ok
      {module, function} ->
        case apply(module, function, [row, AshHooks.Tenancy.from_row(row)]) do
          :ok -> :ok
          _other -> AshHooks.Outbox.emit(:trigger, row, :failed, :trigger_failed)
        end
    end
  rescue
    _error -> AshHooks.Outbox.emit(:trigger, row, :failed, :trigger_failed)
  catch
    _kind, _reason -> AshHooks.Outbox.emit(:trigger, row, :failed, :trigger_failed)
  end
end
