defmodule AshHooks.Endpoint.Verifiers.Overlap do
  @moduledoc false
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  def verify(dsl_state) do
    section = AshHooks.KeyRegistry.Storage.section(dsl_state)
    max = Verifier.get_option(dsl_state, [section], :max_overlap_seconds)
    default = Verifier.get_option(dsl_state, [section], :default_overlap_seconds, 86_400)

    if max && default > max do
      {:error,
       DslError.exception(
         module: Verifier.get_persisted(dsl_state, :module),
         path: [section, :max_overlap_seconds],
         message:
           "max_overlap_seconds (#{max}) must be at least the effective " <>
             "default_overlap_seconds (#{default})"
       )}
    else
      :ok
    end
  end
end
