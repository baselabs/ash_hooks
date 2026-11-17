defmodule AshHooks.Changes.Publish do
  @moduledoc """
  Publishes from an action's result record without changing that result.

  Options are `:outbox`, `:declaration` (`{resource, name}`), `:build`
  (`{module, function}`), and optional `:route` (default `:default`). The
  builder receives `(record, changeset.context)` and returns `{:ok, event}`
  or an error. It runs in `after_action`, inside the action transaction,
  after the result record is available. A refusal rolls back that action.
  Tenant and context come from its changeset. Normal, bulk, and atomic
  writes all use this same hook and `AshHooks.publish/4` operation.

  Use the `AshHooks` extension on the publishing resource for compile-time
  repository verification. A runtime repository or instance mismatch is
  refused before the outbox write. AshSqlite repositories must implement
  `write_transactions?/0` as true.

  <!-- not-run: This action fragment requires the host outbox and result-to-event builder. -->

      change {AshHooks.Changes.Publish,
              outbox: MyApp.Publication,
              declaration: {MyApp.Emitter, :changed},
              build: {MyApp.Events, :from_record},
              route: :default}
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, result ->
      {module, function} = Keyword.fetch!(opts, :build)

      with :ok <-
             AshHooks.Outbox.atomicity(opts[:outbox], changeset.resource,
               context: changeset.context
             ),
           {:ok, event} <- apply(module, function, [result, changeset.context]),
           {:ok, _disposition} <-
             AshHooks.publish(opts[:outbox], opts[:declaration], event,
               tenant: changeset.tenant,
               context: changeset.context,
               caller_resource: changeset.resource,
               route: Keyword.get(opts, :route, :default)
             ) do
        {:ok, result}
      end
    end)
  end

  @impl true
  def atomic(changeset, opts, context), do: {:atomic, change(changeset, opts, context), %{}}
end
