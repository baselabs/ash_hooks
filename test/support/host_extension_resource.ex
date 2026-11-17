defmodule AshHooks.Test.HostExtensionResource do
  @moduledoc false

  defmacro __using__(opts) do
    postgres? = System.get_env("ASH_HOOKS_POSTGRES") == "1"
    layer = if postgres?, do: AshPostgres.DataLayer, else: AshSqlite.DataLayer
    repo = if postgres?, do: AshHooks.TestPostgres.Repo, else: AshHooks.Test.RegistryRepo
    storage = if postgres?, do: :postgres, else: :sqlite
    table = Keyword.fetch!(opts, :table)
    extensions = Keyword.fetch!(opts, :extensions)

    quote do
      use Ash.Resource,
        domain: AshHooks.HostExtensionSeamsTest.Domain,
        data_layer: unquote(layer),
        extensions: unquote(extensions)

      unquote(storage) do
        table unquote(table)
        repo unquote(repo)
      end

      multitenancy do
        strategy :attribute
        attribute :tenant_id
        global? false
      end

      attributes do
        attribute :tenant_id, :string, allow_nil?: false
      end
    end
  end
end
