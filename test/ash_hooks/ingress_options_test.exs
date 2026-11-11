defmodule AshHooks.IngressOptionsTest do
  use ExUnit.Case, async: false
  alias AshHooks.Test.Repo

  defmodule FormProvider do
    @moduledoc false
    @behaviour AshHooks.Provider
    @impl true
    def body_format, do: :form
    @impl true
    def verify_signature(body, ctx, secret),
      do: AshHooks.Provider.default_verify_signature(body, ctx.signature, secret, :hmac_sha256)

    @impl true
    def parse_event_type(%{"type" => "created"}), do: {:ok, :created}
    def parse_event_type(_), do: {:error, :malformed_payload}
    @impl true
    def handle_event(type, payload), do: {:ok, %{type: type, payload: payload}}
  end

  defmodule Ledger do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.IngressOptionsTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks, AshHooks.InboundDelivery]

    sqlite do
      table("ingress_options")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      attribute(:org_id, :string, allow_nil?: false)
    end

    multitenancy do
      strategy(:attribute)
      attribute(:org_id)
    end

    actions do
      defaults([:read])
    end

    webhooks do
      inbound :tenant_options do
        provider(AshHooks.IngressOptionsTest.FormProvider)
        secret(fn tenant -> {:ok, "current-" <> tenant} end)
        previous_secret(fn tenant -> {:ok, "previous-" <> tenant} end)
        paused(fn tenant -> tenant == "paused" end)
      end

      inbound :json_default do
        provider(AshHooks.IngressOptionsTest.JsonProvider)
        secret(fn tenant -> {:ok, "current-" <> tenant} end)
      end

      inbound :env_previous do
        provider(AshHooks.IngressOptionsTest.FormProvider)
        secret(fn tenant -> {:ok, "current-" <> tenant} end)
        previous_secret({:app_env, [:ash_hooks, :ingress_options_previous]})
      end
    end
  end

  defmodule JsonProvider do
    @moduledoc false
    @behaviour AshHooks.Provider
    @impl true
    defdelegate verify_signature(body, ctx, secret), to: FormProvider
    @impl true
    defdelegate parse_event_type(payload), to: FormProvider
    @impl true
    defdelegate handle_event(type, payload), to: FormProvider
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(Ledger)
    end
  end

  setup_all do
    Repo.query!("""
    CREATE TABLE ingress_options (
      id TEXT PRIMARY KEY, provider TEXT NOT NULL, external_event_id TEXT NOT NULL,
      external_event_type TEXT, payload TEXT NOT NULL, payload_digest TEXT NOT NULL,
      status TEXT NOT NULL, fencing_token INTEGER NOT NULL DEFAULT 0,
      lease_expires_at TEXT, error_class TEXT, attempts INTEGER NOT NULL DEFAULT 0,
      org_id TEXT NOT NULL
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX ingress_options_unique_ingest_index ON ingress_options (provider, external_event_id, org_id)"
    )

    on_exit(fn -> Repo.query!("DROP TABLE ingress_options") end)
    :ok
  end

  defp ctx(body, tenant, key) do
    %{
      tenant: tenant,
      signature: Base.encode16(:crypto.mac(:hmac, :sha256, key, body), case: :lower)
    }
  end

  test "tenant pause refuses before verification and storage" do
    assert {:error, :source_paused} =
             AshHooks.Ingress.ingest(Ledger, :tenant_options, "invalid", %{tenant: "paused"})

    assert [] == Ash.read!(Ledger, tenant: "paused", authorize?: false)
  end

  test "tenant previous key verifies only its tenant and preserves exact form bytes" do
    body = "type=created&Body=hello+world%2B%26&item%5Bname%5D=A"

    assert {:ok, :created, row} =
             AshHooks.Ingress.ingest(Ledger, :tenant_options, body, ctx(body, "a", "previous-a"))

    assert row.status == :processed
    assert row.payload == %{"type" => "created", "Body" => "hello world+&", "item[name]" => "A"}
    assert row.payload_digest == Base.encode16(:crypto.hash(:sha256, body), case: :lower)

    assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
             AshHooks.Ingress.ingest(Ledger, :tenant_options, body, ctx(body, "b", "previous-a"))

    assert [] == Ash.read!(Ledger, tenant: "b", authorize?: false)
  end

  test "a provider declaration decodes form data after raw-byte verification" do
    body = "type=created&Body=raw+bytes"

    assert {:ok, :created, %{status: :processed, payload: %{"Body" => "raw bytes"}}} =
             AshHooks.Ingress.ingest(
               Ledger,
               :tenant_options,
               body,
               ctx(body, "form", "current-form")
             )
  end

  test "undeclared bodies retain JSON decoding even with a form content-type" do
    body = "type=created"

    context =
      Map.put(ctx(body, "json", "current-json"), :headers, %{
        "content-type" => "application/x-www-form-urlencoded"
      })

    assert {:ok, :created, %{status: :failed_permanent, error_class: "malformed_payload"}} =
             AshHooks.Ingress.ingest(Ledger, :json_default, body, context)
  end

  test "authenticated form bytes that decode to invalid UTF-8 become a permanent malformed payload" do
    body = "type=created&Body=%FF"

    assert {:ok, :created,
            %{status: :failed_permanent, error_class: "malformed_payload", payload: %{}}} =
             AshHooks.Ingress.ingest(
               Ledger,
               :tenant_options,
               body,
               ctx(body, "bad-form", "current-bad-form")
             )
  end

  test "previous app-env keys accept the documented binary and preserve the legacy tuple shape" do
    on_exit(fn -> Application.delete_env(:ash_hooks, :ingress_options_previous) end)

    for {value, suffix} <- [{"previous-env", "binary"}, {{:ok, "previous-env"}, "legacy"}] do
      Application.put_env(:ash_hooks, :ingress_options_previous, value)
      body = "type=created&source=" <> suffix

      assert {:ok, :created, %{status: :processed}} =
               AshHooks.Ingress.ingest(
                 Ledger,
                 :env_previous,
                 body,
                 ctx(body, "env", "previous-env")
               )
    end

    Application.put_env(:ash_hooks, :ingress_options_previous, "")
    body = "type=created&source=empty"

    assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
             AshHooks.Ingress.ingest(
               Ledger,
               :env_previous,
               body,
               ctx(body, "env", "previous-env")
             )
  end

  test "a route can explicitly choose form or JSON without changing the provider" do
    modules =
      Code.compile_string("""
      defmodule AshHooks.RouteFormatDomain do
        use Ash.Domain, otp_app: nil, validate_config_inclusion?: false
        resources do
          resource(AshHooks.RouteFormatLedger)
        end
      end
      defmodule AshHooks.RouteFormatLedger do
        use Ash.Resource, domain: AshHooks.RouteFormatDomain,
          data_layer: AshSqlite.DataLayer, extensions: [AshHooks, AshHooks.InboundDelivery]
        sqlite do
          table("ingress_options")
          repo(AshHooks.Test.Repo)
        end
        attributes do
          attribute(:org_id, :string, allow_nil?: false)
        end
        multitenancy do
          strategy(:attribute)
          attribute(:org_id)
        end
        actions do
          defaults([:read])
        end
        webhooks do
          inbound :form_route do
            provider(AshHooks.IngressOptionsTest.JsonProvider)
            body_format(:form)
            secret(fn _ -> {:ok, "route-key"} end)
          end
        end
      end
      """)

    on_exit(fn ->
      for {m, _} <- modules do
        :code.purge(m)
        :code.delete(m)
      end
    end)

    body = "type=created&Body=route"

    assert {:ok, :created, %{status: :processed}} =
             AshHooks.Ingress.ingest(
               AshHooks.RouteFormatLedger,
               :form_route,
               body,
               ctx(body, "route", "route-key")
             )
  end
end
