defmodule AshHooks.Outbound do
  @moduledoc false

  defstruct [:name, :signing_mode, :endpoints, entities: [], __spark_metadata__: nil]
end
