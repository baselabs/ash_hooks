defmodule AshHooks.Provider.EasyPostTest do
  use ExUnit.Case, async: false

  alias AshHooks.Provider.{EasyPost, Event}
  alias AshHooks.Test.Repo

  # Independently computed before implementation with Python's standard library,
  # reproducing EasyPost's validate_webhook algorithm, then cross-checked with
  # OpenSSL dgst -sha256 -mac HMAC -macopt hexkey:<UTF-8 key bytes> over @body.
  # https://github.com/EasyPost/easypost-python/blob/7e788d1b92272bbe4e899eab5c923e53f13df778/easypost/util.py
  # Python: hmac.new(unicodedata.normalize("NFKD", key).encode("utf8"),
  #                  body, hashlib.sha256).hexdigest()
  # These are unit vectors, not claims of live EasyPost delivery acceptance.
  @body ~s({"id":"evt_1","description":"tracker.updated"})
  @ascii_mac "0b56c93f30784936100cc12e249dd143dbe61a42cea85c2e6cd3f718198d9c8c"
  @current_mac "f56153af3ad5caebb848c609d3352f626ef57ed4509b467be9b3c2a1f6ff6c85"
  @unicode_key "caf\u00e9-\ufb01-\u2460"
  @normalized_key "cafe\u0301-fi-1"
  @normalized_mac "def65090086adc634f026d5f3ef9ae51633f78b0e466d360636fc35d7af0cd75"
  @unnormalized_mac "3f1a7da6f0d9e1d505962435a6e3e32e8bf8d4ab1b164b06d5e4c336a1f5433c"

  defmodule Ledger do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.Provider.EasyPostTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks, AshHooks.InboundDelivery]

    sqlite do
      table("easy_post_ingress")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read])
    end

    webhooks do
      inbound :easy_post do
        secret({AshHooks.Provider.EasyPostTest, :current_secret, []})
        previous_secret({AshHooks.Provider.EasyPostTest, :previous_secret, []})
      end

      inbound :easy_post_current_only do
        provider(AshHooks.Provider.EasyPost)
        secret({AshHooks.Provider.EasyPostTest, :current_secret, []})
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
    CREATE TABLE easy_post_ingress (
      id TEXT PRIMARY KEY, provider TEXT NOT NULL, external_event_id TEXT NOT NULL,
      external_event_type TEXT, payload TEXT NOT NULL, payload_digest TEXT NOT NULL,
      status TEXT NOT NULL, fencing_token INTEGER NOT NULL DEFAULT 0,
      lease_expires_at TEXT, error_class TEXT, attempts INTEGER NOT NULL DEFAULT 0
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX easy_post_ingress_unique_ingest_index ON easy_post_ingress (provider, external_event_id)"
    )

    on_exit(fn -> Repo.query!("DROP TABLE easy_post_ingress") end)
    :ok
  end

  setup do
    Repo.query!("DELETE FROM easy_post_ingress")
    :ok
  end

  def current_secret, do: {:ok, "current-key"}
  def previous_secret, do: {:ok, @unicode_key}

  defp ctx(mac), do: %{signature: "hmac-sha256-hex=" <> mac}

  test "accepts the independently computed raw-body HMAC-SHA256 vector" do
    assert :ok = EasyPost.verify_signature(@body, ctx(@ascii_mac), "test-key")
  end

  test "rejects changed payload data and JSON whitespace without re-encoding the body" do
    for body <- [String.replace(@body, "tracker.updated", "tracker.created"), @body <> "\n"] do
      assert {:error, :invalid_signature} =
               EasyPost.verify_signature(body, ctx(@ascii_mac), "test-key")
    end

    assert {:error, :invalid_signature} =
             EasyPost.verify_signature(@body, ctx(@ascii_mac), "wrong-key")
  end

  test "requires the exact prefix and lowercase hex, rejecting malformed signature values" do
    for signature <- [
          @ascii_mac,
          "sha256=" <> @ascii_mac,
          "HMAC-SHA256-HEX=" <> @ascii_mac,
          "hmac-sha256-hex=" <> String.upcase(@ascii_mac),
          "hmac-sha256-hex=" <> String.duplicate("z", 64),
          "hmac-sha256-hex=" <> @ascii_mac <> "0",
          "hmac-sha256-hex=" <> @ascii_mac <> ",hmac-sha256-hex=" <> @ascii_mac,
          "hmac-sha256-hex=",
          "",
          nil,
          ["hmac-sha256-hex=" <> @ascii_mac],
          <<255>>
        ] do
      assert {:error, :invalid_signature} =
               EasyPost.verify_signature(@body, %{signature: signature}, "test-key")
    end
  end

  test "NFKD-normalizes the UTF-8 secret, including compatibility characters, before HMAC" do
    refute @unicode_key == @normalized_key
    refute @normalized_mac == @unnormalized_mac
    assert :ok = EasyPost.verify_signature(@body, ctx(@normalized_mac), @unicode_key)
    assert :ok = EasyPost.verify_signature(@body, ctx(@normalized_mac), @normalized_key)

    assert {:error, :invalid_signature} =
             EasyPost.verify_signature(@body, ctx(@unnormalized_mac), @unicode_key)
  end

  test "missing or empty secrets and invalid Unicode secrets fail closed" do
    for secret <- [nil, "", 42] do
      assert {:error, :no_webhook_secret} =
               EasyPost.verify_signature(@body, ctx(@ascii_mac), secret)
    end

    for secret <- [<<255>>, <<195>>] do
      assert {:error, :invalid_signature} =
               EasyPost.verify_signature(@body, ctx(@ascii_mac), secret)
    end
  end

  test "malformed context and body return errors without raising" do
    for context <- [nil, [], %{}, %{signature: 42}] do
      assert {:error, :invalid_signature} =
               EasyPost.verify_signature(@body, context, "test-key")
    end

    assert {:error, :invalid_signature} =
             EasyPost.verify_signature(nil, ctx(@ascii_mac), "test-key")
  end

  test "preserves payloads in a fixed webhook event and declares no signed timestamp" do
    payload = %{"description" => "a-vendor-type-not-in-the-atom-table"}
    assert {:ok, :webhook} = EasyPost.parse_event_type(payload)
    assert {:ok, :webhook} = EasyPost.parse_event_type([payload])
    assert {:error, :malformed_payload} = EasyPost.parse_event_type(nil)

    assert {:ok, %Event{type: :webhook, payload: ^payload}} =
             EasyPost.handle_event(:webhook, payload)

    assert AshHooks.Provider.timestamp_header(EasyPost) == nil
  end

  test "ingress resolves the provider by name, verifies the current key, and deduplicates" do
    assert {:ok, :created, row} =
             AshHooks.Ingress.ingest(Ledger, :easy_post, @body, ctx(@current_mac))

    assert row.status == :processed
    assert row.payload == Jason.decode!(@body)
    assert row.payload_digest == Base.encode16(:crypto.hash(:sha256, @body), case: :lower)

    assert {:ok, :duplicate, duplicate} =
             AshHooks.Ingress.ingest(Ledger, :easy_post, @body, ctx(@current_mac))

    assert duplicate.id == row.id
    assert length(Ash.read!(Ledger, authorize?: false)) == 1
  end

  test "overlapping previous secrets verify through ingress with the same NFKD normalization" do
    assert {:error, :invalid_signature} =
             EasyPost.verify_signature(@body, ctx(@normalized_mac), "current-key")

    assert {:ok, :created, %{status: :processed}} =
             AshHooks.Ingress.ingest(Ledger, :easy_post, @body, ctx(@normalized_mac))

    assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
             AshHooks.Ingress.ingest(Ledger, :easy_post_current_only, @body, ctx(@normalized_mac))

    assert [%{provider: :easy_post}] = Ash.read!(Ledger, authorize?: false)
  end

  test "tampered ingress fails before storage even during secret overlap" do
    assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
             AshHooks.Ingress.ingest(
               Ledger,
               :easy_post,
               String.replace(@body, "tracker.updated", "tracker.created"),
               ctx(@normalized_mac)
             )

    assert [] = Ash.read!(Ledger, authorize?: false)
  end
end
