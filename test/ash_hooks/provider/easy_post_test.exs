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

  # Independently computed with Python hmac/hashlib over the help article's
  # timestamp, method, path and body, concatenated WITHOUT separators:
  # hmac.new(key.encode("utf-8"), (timestamp + method + path).encode("utf-8")
  #          + body, hashlib.sha256).hexdigest()
  # The article publishes sample input but no secret/digest pair or v2 vector;
  # none of the four official SDK validators implements v2 as of 2026-11-10.
  @v2_body ~s({"event":"tracker.created"})
  @v2_timestamp "Tue, 19 Aug 2025 20:37:09 -0000"
  @v2_seconds 1_755_635_829
  @v2_path "/webhook/test"
  @v2_mac "1fcd868bb12771f13b80c413adbbc772f83bbd99b433f10f78dbe8454dfb32ee"

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

  defp v2_ctx(opts \\ []) do
    signature = Keyword.get(opts, :signature, "hmac-sha256-hex=" <> @v2_mac)

    %{
      signature: signature,
      headers: %{
        "x-hmac-signature-v2" => signature,
        "x-timestamp" => Keyword.get(opts, :timestamp, @v2_timestamp),
        "x-path" => Keyword.get(opts, :path, @v2_path)
      },
      method: Keyword.get(opts, :method, "POST"),
      request_uri: Keyword.get(opts, :request_uri, @v2_path),
      now_ms: Keyword.get(opts, :now_ms, @v2_seconds * 1_000)
    }
  end

  # Runtime vectors exercise real ingress against the system clock. The fixed
  # Python vectors above and below independently establish the signing bytes.
  defp current_v2_ctx(body, key, age \\ 0) do
    timestamp =
      DateTime.utc_now()
      |> DateTime.add(-age, :second)
      |> Calendar.strftime("%a, %d %b %Y %H:%M:%S +0000")

    signed_v2_ctx(body, key, timestamp)
    |> Map.delete(:now_ms)
  end

  defp signed_v2_ctx(body, key, timestamp) do
    signature =
      :crypto.mac(:hmac, :sha256, key, timestamp <> "POST" <> @v2_path <> body)
      |> Base.encode16(case: :lower)

    v2_ctx(timestamp: timestamp, signature: "hmac-sha256-hex=" <> signature)
  end

  test "v2 accepts the article's concatenation, case-insensitive prefix and hex" do
    assert :ok = EasyPost.verify_signature(@v2_body, v2_ctx(), "test-key")

    assert :ok =
             EasyPost.verify_signature(
               @v2_body,
               v2_ctx(signature: "HMAC-SHA256-HEX=" <> String.upcase(@v2_mac)),
               "test-key"
             )

    headers = Map.new(v2_ctx().headers, fn {key, value} -> {String.upcase(key), value} end)
    assert :ok = EasyPost.verify_signature(@v2_body, %{v2_ctx() | headers: headers}, "test-key")
  end

  test "v2 preserves empty bodies, UTF-8 bytes and literal encoded paths" do
    for {body, key, path, mac} <- [
          {"", "test-key", @v2_path,
           "a031dc25681c79c2e5c8035a5b7377d179d639da640dd54c599949c4e382fe1c"},
          {@v2_body, @unicode_key, @v2_path,
           "010d535d655385f54d6a6dbaae51a0614b2c489aaa323ed88a1385c8e6e286ed"},
          {~s({"event":"café"}) <> "\n", "test-key", @v2_path,
           "7e97f4cd515756a75bc45439af8297632680e10d2914e7c609938a28ba7eaff0"},
          {@v2_body, "test-key", "/webhook/a%2Fb?x=1&y=2",
           "f5766103f2832004384fc4bfe1a5df7771c1c405dd181d9c8f74a5f6b3eaf281"}
        ] do
      context = v2_ctx(path: path, request_uri: path, signature: "hmac-sha256-hex=" <> mac)
      assert :ok = EasyPost.verify_signature(body, context, key)
    end
  end

  test "v2 parses numeric timezone offsets but signs the original timestamp bytes" do
    for {timestamp, mac} <- [
          {"Wed, 20 Aug 2025 02:07:09 +0530",
           "e1905014ed7229837c4a0d800e5517ec0b409a560d813d3b86e90e1cb8fdc185"},
          {"Tue, 19 Aug 2025 16:37:09 -0400",
           "b1e010eea87c52f19928e6211f1f8cdf57abed79102ba10ccc5bc4e2ab316a88"}
        ] do
      context = v2_ctx(timestamp: timestamp, signature: "hmac-sha256-hex=" <> mac)
      assert :ok = EasyPost.verify_signature(@v2_body, context, "test-key")
    end
  end

  test "v2 accepts at most 60 seconds of age and 30 seconds of future clock skew" do
    for difference <- [-30, 0, 60] do
      context = v2_ctx(now_ms: (@v2_seconds + difference) * 1_000)
      assert :ok = EasyPost.verify_signature(@v2_body, context, "test-key")
    end

    for difference <- [-31, 61, 3_600] do
      context = v2_ctx(now_ms: (@v2_seconds + difference) * 1_000)

      assert {:error, :stale_timestamp} =
               EasyPost.verify_signature(@v2_body, context, "test-key")
    end
  end

  test "v2 rejects tampered method, either path, timestamp, body and key" do
    for context <- [
          v2_ctx(method: "GET"),
          v2_ctx(method: "post"),
          v2_ctx(path: "/other"),
          v2_ctx(request_uri: "/other"),
          v2_ctx(path: "/other", request_uri: "/other"),
          v2_ctx(timestamp: "Tue, 19 Aug 2025 20:37:10 -0000")
        ] do
      assert {:error, :invalid_signature} =
               EasyPost.verify_signature(@v2_body, context, "test-key")
    end

    assert {:error, :invalid_signature} =
             EasyPost.verify_signature(@v2_body <> "\n", v2_ctx(), "test-key")

    assert {:error, :invalid_signature} =
             EasyPost.verify_signature(@v2_body, v2_ctx(), "wrong-key")
  end

  test "v2 rejects missing headers and malformed contexts without raising" do
    for header <- ["x-timestamp", "x-path"] do
      context = %{v2_ctx() | headers: Map.delete(v2_ctx().headers, header)}

      assert {:error, :invalid_signature} =
               EasyPost.verify_signature(@v2_body, context, "test-key")
    end

    for {key, value} <- [method: nil, method: :post, request_uri: nil, request_uri: 42] do
      assert {:error, :invalid_signature} =
               EasyPost.verify_signature(@v2_body, Map.put(v2_ctx(), key, value), "test-key")
    end

    for signature <- [
          nil,
          [],
          "",
          @v2_mac,
          "hmac-sha256-hex=" <> String.duplicate("g", 64),
          "hmac-sha256-hex=" <> @v2_mac <> "0",
          <<255>>
        ] do
      assert {:error, :invalid_signature} =
               EasyPost.verify_signature(@v2_body, v2_ctx(signature: signature), "test-key")
    end
  end

  test "v2 rejects malformed or impossible RFC 2822 timestamps" do
    for timestamp <- [
          nil,
          42,
          "1755635829",
          "",
          <<255>>,
          "Tue, 19 Xxx 2025 20:37:09 -0000",
          "Tue, 32 Aug 2025 20:37:09 -0000",
          "Tue, 29 Feb 2025 20:37:09 -0000",
          "Mon, 19 Aug 2025 20:37:09 -0000",
          "Tue, 19 Aug 2025 24:37:09 -0000",
          "Tue, 19 Aug 2025 20:37:09 +2400",
          "Tue, 19 Aug 2025 20:37:09 +0060",
          "Tue, 19 Aug 2025 20:37:09 UTC"
        ] do
      context =
        if is_binary(timestamp),
          do: signed_v2_ctx(@v2_body, "test-key", timestamp),
          else: v2_ctx(timestamp: timestamp)

      assert {:error, :invalid_signature} =
               EasyPost.verify_signature(@v2_body, context, "test-key")
    end
  end

  test "a present v2 header is authoritative even with a valid v1 signature" do
    for signature <- [nil, [], "", "hmac-sha256-hex=" <> @v2_mac] do
      context = Map.put(v2_ctx(signature: signature), :signature, ctx(@ascii_mac).signature)
      assert {:error, :invalid_signature} = EasyPost.verify_signature(@body, context, "test-key")
    end
  end

  test "v2 ingress verifies current and previous secrets using the existing public path context" do
    for key <- ["current-key", @unicode_key] do
      context = current_v2_ctx(@body, key)

      assert {:ok, _, %{status: :processed}} =
               AshHooks.Ingress.ingest(Ledger, :easy_post, @body, context)
    end

    assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
             AshHooks.Ingress.ingest(
               Ledger,
               :easy_post_current_only,
               @body,
               current_v2_ctx(@body, @unicode_key)
             )
  end

  test "v2 ingress ignores caller clock overrides and rejects old deliveries before storage" do
    for age <- [61, -120] do
      context = current_v2_ctx(@body, "current-key", age)
      context = Map.put(context, :now_ms, System.system_time(:millisecond) - age * 1_000)

      assert {:error, %AshHooks.Errors.Invalid.StaleTimestamp{}} =
               AshHooks.Ingress.ingest(Ledger, :easy_post, @body, context)
    end

    assert [] = Ash.read!(Ledger, authorize?: false)
  end

  test "v2 ingress does not fall back to valid v1 for a stale or invalid v2 envelope" do
    for {context, error_type} <- [
          {current_v2_ctx(@body, "current-key", 61), AshHooks.Errors.Invalid.StaleTimestamp},
          {current_v2_ctx(@body, "wrong-key"), AshHooks.Errors.Invalid.InvalidSignature}
        ] do
      context = Map.put(context, :signature, ctx(@current_mac).signature)

      assert {:error, %{__struct__: ^error_type}} =
               AshHooks.Ingress.ingest(Ledger, :easy_post, @body, context)
    end

    assert [] = Ash.read!(Ledger, authorize?: false)
  end

  test "v2 ingress rejects tampered public request context and bodies during secret overlap" do
    context = current_v2_ctx(@body, @unicode_key)

    for {body, context} <- [
          {@body <> "\n", context},
          {@body, %{context | method: "PUT"}},
          {@body, %{context | request_uri: "/other"}}
        ] do
      assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
               AshHooks.Ingress.ingest(Ledger, :easy_post, body, context)
    end

    assert [] = Ash.read!(Ledger, authorize?: false)
  end

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
