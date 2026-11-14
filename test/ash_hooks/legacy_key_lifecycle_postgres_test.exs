defmodule AshHooks.LegacyKeyLifecyclePostgresTest do
  use ExUnit.Case, async: false
  alias AshHooks.Test.LegacyKeyLifecycleCases, as: Cases
  @moduletag :postgres

  setup_all do
    Cases.setup_all(
      __MODULE__,
      AshPostgres.DataLayer,
      AshHooks.TestPostgres.Repo,
      "pg_legacy_lifecycle"
    )
  end

  setup context do
    Cases.clean(context)
  end

  for name <- Cases.cases() do
    test "legacy lifecycle #{name}", context do
      apply(Cases, unquote(name), [context])
    end
  end

  for name <- Cases.receiver_cases() do
    @tag :real_receiver
    test "legacy signing #{name}", context do
      apply(Cases, unquote(name), [context])
    end
  end
end
