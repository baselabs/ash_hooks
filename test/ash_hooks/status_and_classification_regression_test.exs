defmodule AshHooks.StatusAndClassificationRegressionTest do
  use ExUnit.Case, async: false

  alias AshHooks.Test.Repo
  alias Spark.Dsl.Extension

  defmodule Endpoint do
    use Ash.Resource,
      domain: AshHooks.StatusAndClassificationRegressionTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Endpoint]

    sqlite do
      table("status_normalization_endpoints")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      attribute(:active, :boolean, allow_nil?: false, default: true)
    end

    actions do
      defaults([:read, :create])
      default_accept(:*)
    end

    endpoint do
      status_attribute(:active)
      enabled_values(["true"])
      disabled_value("false")
    end
  end

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered?(true)
      resource(AshHooks.StatusAndClassificationRegressionTest.Endpoint)
    end
  end

  setup_all do
    Repo.query!("""
    CREATE TABLE status_normalization_endpoints (
      id TEXT PRIMARY KEY, active INTEGER NOT NULL,
      url TEXT NOT NULL, secret_ref TEXT NOT NULL,
      previous_secret_ref TEXT, legacy_secret_ref TEXT,
      legacy_previous_secret_ref TEXT
    )
    """)

    on_exit(fn -> Repo.query!("DROP TABLE status_normalization_endpoints") end)
    :ok
  end

  test "cast status values govern actual reads and disable writes" do
    endpoint =
      Ash.create!(
        Endpoint,
        %{url: "https://example.com/webhook", secret_ref: "vault-reference"},
        authorize?: false
      )

    assert AshHooks.Endpoint.enabled?(endpoint)
    disabled = Ash.update!(endpoint, %{}, action: :disable, authorize?: false)
    assert disabled.active == false
    refute AshHooks.Endpoint.enabled?(disabled)
  end

  test "normalized overlap, empty values, and every primary key component are rejected" do
    assert_mapping_error("[true]", ~s("true"), ":active", ~r/inside enabled_values/)
    assert_mapping_error("[]", "false", ":active", ~r/nonempty/)
    assert_mapping_error(~s(["not-a-boolean"]), "false", ":active", ~r/invalid value/)
    assert_mapping_error("[true]", "false", ":key", ~r/primary key/)
  end

  test "an explicit nil disable mapping is allowed only on a nullable attribute" do
    source = mapped_resource("[true]", "nil", ":active", true)
    Code.compile_string(source)
    resource = AshHooks.StatusAndClassificationRegressionTest.InvalidMapping

    try do
      opts = Extension.get_opt(resource, [:endpoint], :disabled_value, :omitted)
      assert opts == nil
    after
      :code.purge(resource)
      :code.delete(resource)
    end

    assert_mapping_error("[true]", "nil", ":active", ~r/invalid|nil/)
  end

  test "classification cannot retain caller-selected secret-shaped tokens or atoms" do
    secret = ("whsec_" <> Base.encode64(:crypto.strong_rand_bytes(24))) |> String.downcase()
    assert AshHooks.Telemetry.classify_token(secret) == "unclassified", "secret token retained"
    assert AshHooks.Telemetry.classify_token("private_consumer_value") == "unclassified"
    assert AshHooks.Telemetry.classify_token(:private_consumer_value) == "unclassified"
    assert AshHooks.Telemetry.classify_token(:timeout) == "timeout"
    assert AshHooks.Telemetry.classify_token("http_502") == "http_502"
    assert AshHooks.Telemetry.classify_token("http_9999") == "unclassified"
    assert AshHooks.Telemetry.classify_token("http_2x0") == "unclassified"
    assert AshHooks.Telemetry.classify_token("http_099") == "unclassified"
    assert AshHooks.Telemetry.classify_token("redirect_refused_302") == "redirect_refused_302"
    assert AshHooks.Telemetry.classify_token("redirect_refused_200") == "unclassified"
  end

  defp assert_mapping_error(enabled, disabled, attribute, regex) do
    source = mapped_resource(enabled, disabled, attribute, false)
    assert_raise Spark.Error.DslError, regex, fn -> Code.compile_string(source) end
  after
    :code.purge(AshHooks.StatusAndClassificationRegressionTest.InvalidMapping)
    :code.delete(AshHooks.StatusAndClassificationRegressionTest.InvalidMapping)
  end

  defp mapped_resource(enabled, disabled, attribute, nullable?) do
    """
    defmodule AshHooks.StatusAndClassificationRegressionTest.InvalidMapping do
      use Ash.Resource, domain: AshHooks.StatusAndClassificationRegressionTest.Domain,
        validate_domain_inclusion?: false,
        data_layer: Ash.DataLayer.Ets, extensions: [AshHooks.Endpoint]
      attributes do
        attribute :key, :boolean, primary_key?: true, allow_nil?: false, default: true
        attribute :active, :boolean, allow_nil?: #{nullable?}, default: true
      end
      actions do
        defaults [:read]
      end
      endpoint do
        status_attribute #{attribute}
        enabled_values #{enabled}
        disabled_value #{disabled}
      end
    end
    """
  end
end
