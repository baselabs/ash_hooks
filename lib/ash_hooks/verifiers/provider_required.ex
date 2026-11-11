defmodule AshHooks.Verifiers.ProviderRequired do
  @moduledoc false
  use Spark.Dsl.Verifier
  alias Spark.Dsl.Verifier

  def verify(dsl_state) do
    resource = Verifier.get_persisted(dsl_state, :module)

    dsl_state
    |> Verifier.get_entities([:webhooks])
    |> Enum.filter(&is_struct(&1, AshHooks.Inbound))
    |> Enum.each(fn inbound ->
      if is_nil(inbound.provider) do
        raise Spark.Error.DslError,
          module: resource,
          path: [:webhooks, :inbound, inbound.name],
          message:
            "inbound #{inspect(inbound.name)} has no provider. ash_hooks ships no built-in verifiers since 3.0.0: set `provider` to a module that implements AshHooks.Provider, for example one defined with `use AshHooks.Provider, verify: [...]`."
      end
    end)

    :ok
  end
end
