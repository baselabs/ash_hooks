defmodule AshHooks.Binding do
  @moduledoc """
  Names the physical database binding used by a generated `AshHooks.Worker`.

  The host installs its Ecto dynamic repos before publishing, dispatching, or
  running maintenance. The worker persists the binding name in each new job
  and calls this behavior to install the same repositories when that job runs.
  Keep the name stable across processes, nodes, and deployments while jobs
  with that name remain runnable.
  """

  @typedoc "A nonempty UTF-8 string without a null byte, safe to persist in Oban job args."
  @type name :: String.t()

  @doc "Returns the name of the binding already installed in the calling process."
  @callback current() :: name()

  @doc """
  Installs the Ecto dynamic repositories for the named binding in this process.

  Return `:ok` after installing them. Return `{:error, :unknown_binding}` for
  an unrecognized name so Oban cancels the job without accessing storage.
  Derive `current/0` from the installed repositories. The worker restores its
  resources' previous dynamic repositories after a job.
  """
  @callback bind(name()) :: :ok | {:error, :unknown_binding}

  @doc "Returns the Oban instance name configured for this binding."
  @callback oban(name()) :: term()
end
