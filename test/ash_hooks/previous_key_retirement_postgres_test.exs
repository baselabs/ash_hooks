defmodule AshHooks.PreviousKeyRetirementPostgresTest do
  @moduledoc false
  use AshHooks.Test.PreviousKeyRetirementCases,
    data_layer: AshPostgres.DataLayer,
    repo: AshHooks.TestPostgres.Repo,
    prefix: "pg_previous_key_retirement"
end
