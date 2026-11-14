defmodule AshHooks.Verifiers.SourceLedger do
  @moduledoc false
  use Spark.Dsl.Verifier
  alias Spark.Dsl.{Extension, Verifier}

  def verify(state) do
    resource = Verifier.get_persisted(state, :module)

    for %AshHooks.Inbound{source_record: source, name: name} <-
          Verifier.get_entities(state, [:webhooks]),
        not is_nil(source) do
      Code.ensure_compiled!(source)

      if Extension.get_opt(source, [:inbound_source], :ledger) != resource do
        raise Spark.Error.DslError,
          module: resource,
          path: [:webhooks, :inbound, name],
          message: "source_record ledger must be this resource"
      end
    end

    :ok
  end
end
