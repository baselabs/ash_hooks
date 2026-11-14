defmodule AshHooks.Endpoint.Verifiers.LegacyLifecycle do
  @moduledoc false
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  def verify(dsl_state) do
    if Verifier.get_option(dsl_state, [:endpoint], :legacy_key_lifecycle, :off) == :on and
         Verifier.get_option(dsl_state, [:endpoint], :key_lifecycle, :off) != :on do
      {:error,
       DslError.exception(
         module: Verifier.get_persisted(dsl_state, :module),
         path: [:endpoint, :legacy_key_lifecycle],
         message: "legacy_key_lifecycle :on requires key_lifecycle :on"
       )}
    else
      :ok
    end
  end
end
