defmodule AshHooks.Test.Dsl do
  @moduledoc false
  require Spark.Test

  # Keep one use of Spark's structured collector. All dynamic DSL fixtures use
  # Module.create/3, so verification shares the defining process even before
  # Spark 2.7.9 added collector propagation to compiler checker processes.
  def errors(fun) do
    Spark.Test.dsl_errors(do: fun.())
  end
end
