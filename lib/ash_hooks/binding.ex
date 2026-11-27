defmodule AshHooks.Binding do
  @moduledoc """
  Names the physical database binding used by a generated `AshHooks.Worker`.

  The host installs its Ecto dynamic repos before publishing, dispatching, or
  running maintenance. The worker persists the binding name in each new job
  and calls this behavior in the job process and its delivery or fanout children.
  Keep the name stable across processes, nodes, and deployments while jobs
  with that name remain runnable.

  Oban's `:get_dynamic_repo` wraps Oban's own repo calls. A host maintenance
  worker run by Oban Cron or another plugin must call `bind/1` in `perform/1`
  before running publication sweeps, delivery reconciliation, or reapers.
  Schedule each maintenance job once per binding and pass the binding name
  in its job args. See the
  [maintenance example](tenancy-adoption-checklist.md#maintenance-jobs).
  """

  @typedoc "A nonempty UTF-8 string without a null byte, safe to persist in Oban job args."
  @type name :: String.t()

  @doc "Returns the name of the binding already installed in the calling process."
  @callback current() :: name()

  @doc """
  Installs the Ecto dynamic repositories for the named binding in this process.

  Return `:ok` after installing them. Return `{:error, :unknown_binding}` for
  an unrecognized name so Oban cancels the job without accessing storage.
  Derive `current/0` from the installed repositories. The worker restores the
  previous dynamic selections of running repos and its resource repos after
  a job. A callback that raises fails the job with `{:error, :binding_failed}`.
  """
  @callback bind(name()) :: :ok | {:error, :unknown_binding}

  @doc "Returns the Oban instance name configured for this binding."
  @callback oban(name()) :: term()
end
