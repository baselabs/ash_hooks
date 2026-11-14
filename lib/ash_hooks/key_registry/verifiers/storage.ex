defmodule AshHooks.KeyRegistry.Verifiers.Storage do
  @moduledoc false
  use Spark.Dsl.Verifier
  alias Ash.Resource.Info
  alias AshHooks.KeyRegistry.Storage
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  def verify(state) do
    cond do
      not Storage.supported?(state) ->
        error(state, "key registries require AshPostgres or AshSqlite with transaction support")

      Info.primary_key(state) != [:ref] ->
        error(state, "key registries require ref as their sole primary key")

      true ->
        :ok
    end
  end

  defp error(state, message) do
    {:error,
     DslError.exception(
       module: Verifier.get_persisted(state, :module),
       path: [:key_registry],
       message: message
     )}
  end
end
