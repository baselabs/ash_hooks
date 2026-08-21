defmodule AshHooks.Verifiers.NoLiteralSecrets do
  @moduledoc false

  # ADR-0005 floor: a signing secret as a DSL literal would live in compiled
  # DSL data and BEAM artifacts. The DSL accepts a source — `{m, f, a}`,
  # `{:app_env, path}`, or a zero-arity function — never the bytes.
  use Spark.Dsl.Verifier

  @impl Spark.Dsl.Verifier
  def verify(dsl_state) do
    Spark.Dsl.Verifier.get_entities(dsl_state, [:webhooks])
    |> Enum.filter(&is_struct(&1, AshHooks.Inbound))
    |> Enum.filter(&is_binary(&1.secret))
    |> case do
      [] ->
        :ok

      [first | _] ->
        {:error,
         Spark.Error.DslError.exception(
           module: Spark.Dsl.Verifier.get_persisted(dsl_state, :module),
           path: [:webhooks, :inbound, first.name],
           message: """
           secret must be a SOURCE, not a literal binary — {m, f, a},
           {:app_env, path}, or a function returning
           {:ok, secret} | {:error, :no_webhook_secret}. Literals end up in
           compiled DSL data and BEAM artifacts (ADR-0005).
           """
         )}
    end
  end
end
