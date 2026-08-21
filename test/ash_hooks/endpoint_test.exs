defmodule AshHooks.EndpointTest do
  @moduledoc """
  The Endpoint resource floor: durable enable/disable state and
  secret REFERENCES (never secret material — a `whsec_`-shaped value is
  rejected at cast, on every write path, because the type itself refuses
  it: ADR-0005's runtime twin of the compile-time literal net).
  """

  defmodule Endpoint do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.EndpointTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Endpoint]

    sqlite do
      table("endpoint_test_endpoints")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read, :create, :update])
      default_accept(:*)
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(AshHooks.EndpointTest.Endpoint)
    end
  end

  use ExUnit.Case, async: false

  alias AshHooks.Test.Repo

  @table "endpoint_test_endpoints"

  setup_all do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@table} (
      id TEXT PRIMARY KEY,
      url TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'enabled',
      secret_ref TEXT NOT NULL,
      previous_secret_ref TEXT,
      legacy_secret_ref TEXT,
      legacy_previous_secret_ref TEXT
    )
    """)

    on_exit(fn -> Repo.query!("DROP TABLE IF EXISTS #{@table}") end)
    :ok
  end

  setup do
    Repo.query!("DELETE FROM #{@table}")
    :ok
  end

  defp create!(attrs) do
    Ash.create!(Endpoint, attrs, authorize?: false)
  end

  describe "injected fields" do
    test "creates with defaults: status :enabled, no rotation refs" do
      endpoint = create!(url: "https://example.test/hook", secret_ref: "stripe-main")

      assert endpoint.status == :enabled
      assert endpoint.secret_ref == "stripe-main"
      assert endpoint.previous_secret_ref == nil
      assert endpoint.legacy_secret_ref == nil
      assert endpoint.legacy_previous_secret_ref == nil
    end

    test "url and secret_ref are required" do
      assert {:error, _} = Ash.create(Endpoint, %{url: "https://example.test"}, authorize?: false)
      assert {:error, _} = Ash.create(Endpoint, %{secret_ref: "x"}, authorize?: false)
    end
  end

  describe "secret-shaped literals are rejected at cast (tripwire)" do
    test "rejects a whsec_ literal on create" do
      literal = "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))

      assert {:error, error} =
               Ash.create(Endpoint, %{url: "https://e.test/h", secret_ref: literal},
                 authorize?: false
               )

      assert error_message(error) =~ "secret material"
    end

    test "rejects a whsk_ literal on create" do
      literal = "whsk_" <> Base.encode64(:crypto.strong_rand_bytes(32))

      assert {:error, _} =
               Ash.create(Endpoint, %{url: "https://e.test/h", secret_ref: literal},
                 authorize?: false
               )
    end

    test "rejects a whpk_ literal on create" do
      literal = "whpk_" <> Base.encode64(:crypto.strong_rand_bytes(32))

      assert {:error, _} =
               Ash.create(Endpoint, %{url: "https://e.test/h", secret_ref: literal},
                 authorize?: false
               )
    end

    test "rejects a whsec_ literal sneaking through a DIFFERENT field and the update path" do
      literal = "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))
      endpoint = create!(url: "https://e.test/h", secret_ref: "ok-ref")

      # type-level rejection: the previous/legacy ref columns share the type,
      # and the UPDATE path (a consumer-defined action) casts identically.
      assert {:error, _} =
               Ash.update(endpoint, %{previous_secret_ref: literal}, authorize?: false)

      assert {:error, _} =
               Ash.update(endpoint, %{legacy_secret_ref: literal}, authorize?: false)
    end
  end

  defp error_message(error) do
    cond do
      is_binary(error) -> error
      is_exception(error) -> Exception.message(error)
      true -> inspect(error)
    end
  end
end
