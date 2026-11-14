defmodule AshHooks.PreviousKeyRetirementTest do
  @moduledoc false
  use AshHooks.Test.PreviousKeyRetirementCases,
    data_layer: AshSqlite.DataLayer,
    repo: AshHooks.Test.Repo,
    prefix: "previous_key_retirement"
end
