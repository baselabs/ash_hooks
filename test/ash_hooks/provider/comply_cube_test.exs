defmodule AshHooks.Provider.ComplyCubeTest do
  @moduledoc """
  The ComplyCube vendor verifier: provider-published vector (official PHP SDK
  unit-test fixture, #9 probe — never self-signed), scheme floors, and the
  vendor-documented taxonomy (API reference, fetched first-hand 2026-08-21).
  """

  use ExUnit.Case, async: true

  alias AshHooks.Provider
  alias AshHooks.Provider.ComplyCube

  # Digest reproduced locally with openssl 2026-08-21 (see
  # .kimosabe/research/complycube-vector.md for SDK provenance).
  @vector_secret "a_webhook_signature"
  @vector_body ~s({"id":"value"})
  @vector_signature "bc00414fa4d54277a3ed01e5ee258d9800a918a7791c7cda16d38b82f38f2150"

  # The vendor's documented taxonomy — identical set to the incumbent
  # reference adapter's production map. The test pins every entry: dropping a
  # mapping silently downgrades a real vendor event to unknown_event_type.
  @taxonomy %{
    "client.created" => :client_created,
    "client.updated" => :client_updated,
    "client.deleted" => :client_deleted,
    "document.created" => :document_created,
    "document.updated" => :document_updated,
    "document.updated.image_uploaded" => :document_updated_image_uploaded,
    "document.updated.image_deleted" => :document_updated_image_deleted,
    "document.deleted" => :document_deleted,
    "address.created" => :address_created,
    "address.updated" => :address_updated,
    "address.deleted" => :address_deleted,
    "check.pending" => :check_pending,
    "check.completed" => :check_completed,
    "check.completed.clear" => :check_completed_clear,
    "check.completed.attention" => :check_completed_attention,
    "check.completed.rejected" => :check_completed_rejected,
    "check.completed.match_confirmed" => :check_completed_match_confirmed,
    "check.monitoring.attention" => :check_monitoring_attention,
    "check.failed" => :check_failed,
    "check.updated" => :check_updated,
    "workflow.session.started" => :workflow_session_started,
    "workflow.session.cancelled" => :workflow_session_cancelled,
    "workflow.session.processing" => :workflow_session_processing,
    "workflow.session.completed" => :workflow_session_completed,
    "workflow.session.updated" => :workflow_session_updated
  }

  defp ctx(signature), do: %{signature: signature, headers: %{}}

  describe "verify_signature/3 — provider-published vector" do
    test "accepts the official SDK fixture verbatim" do
      assert :ok =
               ComplyCube.verify_signature(@vector_body, ctx(@vector_signature), @vector_secret)
    end
  end

  describe "verify_signature/3 — tamper + scheme floors" do
    setup do
      secret = "cc-floor-secret"
      body = ~s({"id":"evt_1","type":"check.completed"})
      signature = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
      %{floor_secret: secret, floor_body: body, floor_signature: signature}
    end

    test "rejects a body whose FIRST byte was tampered", %{
      floor_body: body,
      floor_secret: secret,
      floor_signature: signature
    } do
      tampered_body = flip_first_byte(body)

      assert {:error, :invalid_signature} =
               ComplyCube.verify_signature(tampered_body, ctx(signature), secret)
    end

    test "rejects uppercase hex — the canonical digest is lowercase (Python/PHP SDKs compare case-sensitively)",
         %{floor_body: body, floor_secret: secret, floor_signature: signature} do
      assert {:error, :invalid_signature} =
               ComplyCube.verify_signature(body, ctx(String.upcase(signature)), secret)
    end

    test "rejects wrong-length, non-hex, and base64-shaped headers as tuples, never crashes",
         %{floor_body: body, floor_secret: secret, floor_signature: signature} do
      for bad <- [
            String.slice(signature, 0, 63),
            signature <> "0",
            String.duplicate("z", 64),
            String.duplicate("A", 44),
            ""
          ] do
        assert {:error, :invalid_signature} = ComplyCube.verify_signature(body, ctx(bad), secret)
      end
    end

    test "rejects a signature computed under a different secret", %{
      floor_body: body,
      floor_signature: signature
    } do
      assert {:error, :invalid_signature} =
               ComplyCube.verify_signature(body, ctx(signature), "other-secret")
    end

    test "an EMPTY secret fails closed as :no_webhook_secret (empty-key HMAC is forgeable)",
         %{floor_body: body} do
      forged = :crypto.mac(:hmac, :sha256, "", body) |> Base.encode16(case: :lower)

      assert {:error, :no_webhook_secret} =
               ComplyCube.verify_signature(body, ctx(forged), "")
    end
  end

  describe "parse_event_type/1 — vendor taxonomy allowlist" do
    test "maps every documented event type to a pre-existing atom (no atom creation)" do
      for {raw, type} <- @taxonomy do
        assert {:ok, ^type} = ComplyCube.parse_event_type(%{"type" => raw})
      end
    end

    test "an unknown vendor type fails closed as unknown_event_type" do
      assert {:error, :unknown_event_type} =
               ComplyCube.parse_event_type(%{"type" => "nonsense.type"})
    end

    test "missing, non-binary, and JSON-scalar types are malformed" do
      for payload <- [
            %{},
            %{"id" => "evt_1"},
            %{"type" => nil},
            %{"type" => true},
            %{"type" => false},
            %{"type" => 42}
          ] do
        assert {:error, :malformed_payload} = ComplyCube.parse_event_type(payload)
      end
    end
  end

  describe "handle_event/2" do
    test "echoes a generic typed event (domain mapping is consumer-side)" do
      payload = %{
        "id" => "evt_1",
        "type" => "check.completed",
        "payload" => %{"outcome" => "clear"}
      }

      assert {:ok, %ComplyCube.Event{type: :check_completed, payload: ^payload}} =
               ComplyCube.handle_event(:check_completed, payload)
    end
  end

  describe "scheme defaults" do
    test "secret scope is app-level — the endpoint secret rides the DSL secret source" do
      assert Provider.secret_scope(ComplyCube) == :app_level
    end

    test "declares no timestamp header — the scheme has none" do
      assert Provider.timestamp_header(ComplyCube) == nil
    end
  end

  # NOTE: the COMPILE-time fence (ReplayWindowRequiresTimestamp raising a
  # DslError for a resolvable timestamp-less provider + replay_window_seconds)
  # is real but untestable via assert_raise from inside the suite — a module
  # defined at runtime gets its verifier raises downgraded to printed warnings
  # by Spark (post-consolidation compile). Observed live while building this:
  # the probe resource printed
  #   `warning: ** (Spark.Error.DslError) [...] webhooks -> inbound -> comply_cube :`
  # The runtime backstop below is the guaranteed fence — proven for the
  # RESOLVABLE-provider path here (ingress_test's :neverloaded covers the
  # unresolvable path).

  def secret, do: {:ok, "fence-secret"}

  # flip to a DIFFERENT byte — replacing with a constant can no-op when the
  # original already equals it (first-byte tamper trap).
  defp flip_first_byte(<<first, rest::binary>>) do
    replacement = if first == ?x, do: ?y, else: ?x
    <<replacement, rest::binary>>
  end
end

defmodule AshHooks.Provider.ComplyCubeE2ETest do
  @moduledoc """
  Runtime smoke through the real DSL surface: a convention-resolved
  `inbound :comply_cube` (no explicit provider opt) on a real sqlite ledger.
  """

  defmodule Ledger do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.Provider.ComplyCubeE2ETest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks, AshHooks.InboundDelivery]

    sqlite do
      table("comply_cube_e2e_ledgers")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read])
    end

    webhooks do
      inbound :comply_cube do
        secret {AshHooks.Provider.ComplyCubeE2ETest, :secret, []}
        event_id(&__MODULE__.event_id/1)
      end

      # Timestamp-less scheme + window: rejected by the ingress runtime
      # backstop (the compile verifier's raise is downgraded to a warning on
      # runtime-compiled modules — see the note in ComplyCubeTest).
      inbound :comply_cube_windowed do
        provider(AshHooks.Provider.ComplyCube)
        secret {AshHooks.Provider.ComplyCubeE2ETest, :secret, []}
        replay_window_seconds(300)
      end
    end

    def event_id(%{"id" => id}) when is_binary(id), do: {:ok, id}
    def event_id(_payload), do: :error
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(AshHooks.Provider.ComplyCubeE2ETest.Ledger)
    end
  end

  use ExUnit.Case, async: false

  alias AshHooks.Ingress
  alias AshHooks.Test.Repo

  @table "comply_cube_e2e_ledgers"
  # The SDK vector's own secret, supplied through the DSL secret source — the
  # convention an app-level endpoint uses.
  @secret "a_webhook_signature"

  setup_all do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@table} (
      id TEXT PRIMARY KEY,
      provider TEXT NOT NULL,
      external_event_id TEXT NOT NULL,
      external_event_type TEXT,
      payload TEXT NOT NULL,
      payload_digest TEXT NOT NULL,
      status TEXT NOT NULL,
      fencing_token INTEGER NOT NULL DEFAULT 0,
      lease_expires_at TEXT,
      error_class TEXT,
      attempts INTEGER NOT NULL DEFAULT 0
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@table}_unique_ingest_index ON #{@table} (provider, external_event_id)"
    )

    on_exit(fn ->
      Repo.query!("DROP TABLE IF EXISTS #{@table}")
    end)

    :ok
  end

  setup do
    Repo.query!("DELETE FROM #{@table}")
    :ok
  end

  def secret, do: {:ok, @secret}

  defp sign(body), do: :crypto.mac(:hmac, :sha256, @secret, body) |> Base.encode16(case: :lower)

  defp delivery(id) do
    Jason.encode!(%{
      "id" => id,
      "type" => "check.completed",
      "resourceType" => "check",
      "payload" => %{"id" => "chk_1", "status" => "complete", "outcome" => "clear"},
      "createdAt" => "2026-08-21T00:00:00Z"
    })
  end

  defp rows do
    require Ash.Query
    Ash.Query.filter(Ledger, provider == :comply_cube) |> Ash.read!(authorize?: false)
  end

  test "an SDK-scheme delivery verifies and processes through the fenced pipeline" do
    raw = delivery("evt_cc_1")

    assert {:ok, :created, delivery_row} =
             Ingress.ingest(Ledger, :comply_cube, raw, %{signature: sign(raw), headers: %{}})

    assert delivery_row.status == :processed
    assert delivery_row.external_event_id == "evt_cc_1"
    assert delivery_row.external_event_type == "check_completed"
    assert [%{status: :processed}] = rows()
  end

  test "a redelivery of the same event is a duplicate no-op" do
    raw = delivery("evt_cc_2")

    assert {:ok, :created, _} =
             Ingress.ingest(Ledger, :comply_cube, raw, %{signature: sign(raw), headers: %{}})

    assert {:ok, :duplicate, delivery_row} =
             Ingress.ingest(Ledger, :comply_cube, raw, %{signature: sign(raw), headers: %{}})

    assert delivery_row.status == :processed
    assert [%{attempts: 1}] = rows()
  end

  test "an aged delivery still verifies — the scheme carries no replay window" do
    raw = delivery("evt_cc_3")

    stale_headers = %{"date" => "Mon, 01 Jan 2024 00:00:00 GMT"}

    assert {:ok, :created, delivery_row} =
             Ingress.ingest(Ledger, :comply_cube, raw, %{
               signature: sign(raw),
               headers: stale_headers
             })

    assert delivery_row.status == :processed
  end

  test "a tampered delivery is rejected BEFORE any ledger write" do
    raw = delivery("evt_cc_4")
    <<_first, rest::binary>> = raw
    tampered = <<?x, rest::binary>>

    assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
             Ingress.ingest(Ledger, :comply_cube, tampered, %{signature: sign(raw), headers: %{}})

    assert [] = rows()
  end

  test "a replay window on a ComplyCube inbound is rejected at runtime before any write" do
    raw = delivery("evt_cc_5")

    assert {:error, %AshHooks.Errors.Unknown.UnknownError{} = error} =
             Ingress.ingest(Ledger, :comply_cube_windowed, raw, %{
               signature: sign(raw),
               headers: %{}
             })

    assert Exception.message(error) =~ "timestamp"
    assert [] = rows()
  end
end
