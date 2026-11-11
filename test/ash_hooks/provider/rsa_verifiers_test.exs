defmodule AshHooks.Provider.RsaVerifiersTest do
  use ExUnit.Case, async: false
  alias AshHooks.Provider.{Magento2, Wix}
  alias AshHooks.Test.Repo

  # RFC 7515 Appendix A.2 public key and known RS256 signature. No private
  # material is needed. This anchors the cryptographic scheme, not a claim of
  # Wix live-delivery conformance (Wix publishes no complete keyed vector).
  @rfc_n "ofgWCuLjybRlzo0tZWJjNiuSfb4p4fAkd_wWJcyQoTbji9k0l8W26mPddxHmfHQp-Vaw-4qPCJrcS2mJPMEzP1Pt0Bm4d4QlL-yRT-SFd2lZS-pCgNMsD1W_YpRPEwOWvG6b32690r2jZ47soMZo9wGzjb_7OMg0LOL-bSf63kpaSHSXndS5z5rexMdbBYUsLA9e-KXBdQOS-UTo7WTBEMa2R2CapHg665xsmtdVMTBQY4uDZlxvb3qCo5ZwKh9kG4LT6_I5IhlJH7aGhyxXFvUK-DWNmoudF8NAco9_h9iaGNj8q2ethFkMLs91kzk2PAcDTW9gb54h4FRWyuXpoQ"
  # Public RFC 7515 Appendix A.2 test vector; exact scanner fingerprint is allowlisted.
  @rfc_jwt "eyJhbGciOiJSUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ.cC4hiUPoj9Eetdgtv3hF80EGrhuB__dzERat0XF9g2VtQgr9PJbu3XOiZj5RZmh7AAuHIm4Bh-0Qc_lF5YKt_O8W2Fp5jujGbds9uJdbF9CUAr7t1dnZcAcQjbKBYNX4BAynRFdiuB--f_nZLgrnbyTyWzO75vRK5h6xBArLIARNPvkSjtQBMHlb1L07Qe7K0GarZRmB_eSN9383LcOLn6_dO--xi12jzDwusC-eOkHWEsqtFZESc6BfI7noOPqvhJ1phCnvWh6IeYI2w9QOYEUipUTI8np6LbgGY9Fs98rqVt5AXLIhWkWywlVmtVrBp0igcN_IoypGlUPQGe77Rw"

  defmodule Ledger do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.Provider.RsaVerifiersTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks, AshHooks.InboundDelivery]

    sqlite do
      table("rsa_verifier_ingress")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read])
    end

    webhooks do
      inbound :wix do
        secret({AshHooks.Provider.RsaVerifiersTest, :public_key_source, []})
      end
    end
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
    CREATE TABLE rsa_verifier_ingress (
      id TEXT PRIMARY KEY, provider TEXT NOT NULL, external_event_id TEXT NOT NULL,
      external_event_type TEXT, payload TEXT NOT NULL, payload_digest TEXT NOT NULL,
      status TEXT NOT NULL, fencing_token INTEGER NOT NULL DEFAULT 0,
      lease_expires_at TEXT, error_class TEXT, attempts INTEGER NOT NULL DEFAULT 0
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX rsa_verifier_ingress_unique_ingest_index ON rsa_verifier_ingress (provider, external_event_id)"
    )

    on_exit(fn -> Repo.query!("DROP TABLE rsa_verifier_ingress") end)
    :ok
  end

  def public_key_source do
    {pem, 0} =
      System.cmd("openssl", ["pkey", "-in", "test/fixtures/tls/server.key", "-pubout"],
        stderr_to_stdout: true
      )

    {:ok, pem}
  end

  defp sign(input) do
    path = Path.join(System.tmp_dir!(), "ash-hooks-rsa-#{Ash.UUID.generate()}")
    File.write!(path, input)

    try do
      {signature, 0} =
        System.cmd("openssl", ["dgst", "-sha256", "-sign", "test/fixtures/tls/server.key", path])

      signature
    after
      File.rm!(path)
    end
  end

  defp jwt(claims, header \\ %{"alg" => "RS256", "typ" => "JWT"}) do
    input =
      Base.url_encode64(Jason.encode!(header), padding: false) <>
        "." <> Base.url_encode64(Jason.encode!(claims), padding: false)

    input <> "." <> Base.url_encode64(sign(input), padding: false)
  end

  test "Wix verifies the published RS256 known answer and enforces its expiration" do
    modulus = @rfc_n |> Base.url_decode64!(padding: false) |> :binary.decode_unsigned()

    pem =
      :public_key.pem_encode([
        :public_key.pem_entry_encode(:RSAPublicKey, {:RSAPublicKey, modulus, 65_537})
      ])

    assert :ok = Wix.verify_signature(@rfc_jwt, %{now_ms: 1_300_819_379_000}, pem)

    assert {:error, :stale_timestamp} =
             Wix.verify_signature(@rfc_jwt, %{now_ms: 1_300_819_380_000}, pem)

    assert {:error, :invalid_signature} =
             Wix.verify_signature(
               String.replace(@rfc_jwt, "eyJpc3Mi", "eyJpc3Nj"),
               %{now_ms: 1_300_819_379_000},
               pem
             )
  end

  test "Wix pins RS256, rejects malformed JWTs, unknown critical headers, and future/invalid time claims" do
    {:ok, pem} = public_key_source()

    for {claims, header} <- [
          {%{"data" => %{}}, %{"alg" => "none"}},
          {%{"data" => %{}}, %{"alg" => "HS256"}},
          {%{"data" => %{}}, %{"alg" => "RS256", "crit" => ["unknown"]}},
          {%{"exp" => "forever"}, %{"alg" => "RS256"}},
          {%{"exp" => nil}, %{"alg" => "RS256"}},
          {%{"nbf" => nil}, %{"alg" => "RS256"}},
          {%{"nbf" => System.system_time(:second) + 3600}, %{"alg" => "RS256"}}
        ] do
      assert {:error, _} = Wix.verify_signature(jwt(claims, header), %{}, pem)
    end

    for body <- ["", "not.jwt", "a.b.c", <<255>>, "a.b.c.d"] do
      assert {:error, :invalid_signature} = Wix.verify_signature(body, %{}, pem)
    end

    assert {:error, :no_webhook_secret} = Wix.verify_signature(@rfc_jwt, %{}, "")
    assert {:error, :invalid_signature} = Wix.verify_signature(@rfc_jwt, %{}, "not a key")
  end

  test "Wix body JWTs verify without a signature header and persist claims only after verification" do
    claims = %{
      "data" => %{
        "eventType" => "wix.ecom.v1.order_created",
        "instanceId" => "instance-test",
        "data" => "{}"
      }
    }

    token = jwt(claims)
    assert {:ok, :created, row} = AshHooks.Ingress.ingest(Ledger, :wix, token, %{})
    assert row.status == :processed
    assert row.payload == claims
    assert row.payload_digest == Base.encode16(:crypto.hash(:sha256, token), case: :lower)
    assert {:ok, :duplicate, duplicate} = AshHooks.Ingress.ingest(Ledger, :wix, token, %{})
    assert duplicate.id == row.id

    assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
             AshHooks.Ingress.ingest(Ledger, :wix, token <> "broken", %{})

    assert length(Ash.read!(Ledger, authorize?: false)) == 1
  end

  test "Magento 2 native Adobe Commerce signs base64 of the exact body with RSA-SHA256" do
    {:ok, pem} = public_key_source()
    body = ~s({"address": {"postcode": "50000"}})
    ctx = %{signature: Base.encode64(sign(Base.encode64(body)))}
    assert :ok = Magento2.verify_signature(body, ctx, pem)
    assert {:error, :invalid_signature} = Magento2.verify_signature(body <> " ", ctx, pem)

    assert {:error, :invalid_signature} =
             Magento2.verify_signature(body, %{signature: Base.encode64(sign(body))}, pem)

    assert {:error, :invalid_signature} =
             Magento2.verify_signature(body, %{signature: "bad"}, pem)

    assert {:error, :invalid_signature} = Magento2.verify_signature(body, ctx, "not a key")
    assert {:error, :no_webhook_secret} = Magento2.verify_signature(body, ctx, "")

    assert {:error, :invalid_signature} =
             Magento2.verify_signature(
               body,
               ctx,
               "-----BEGIN PUBLIC KEY-----\nYQ==\n-----END PUBLIC KEY-----"
             )

    assert {:error, :invalid_signature} =
             Wix.verify_signature(jwt(%{}), %{now_ms: "invalid"}, pem)
  end
end
