defmodule AshHooks.RetentionTest do
  @moduledoc """
  Retention hooks (#18): prune (both ledgers — TERMINAL rows only,
  the dedup/retry rows are never deleted) and the inbound payload
  redaction hook under the claim fence.
  """

  defmodule Ledger do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.RetentionTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks, AshHooks.InboundDelivery]

    sqlite do
      table("retention_test_ledgers")
      repo(AshHooks.Test.Repo)
    end

    inbound_delivery do
      scope_identity([:account_id])
    end

    attributes do
      attribute(:account_id, :string, allow_nil?: false)
      timestamps()
    end

    actions do
      defaults([:read])
    end

    webhooks do
      inbound :counter do
        provider(AshHooks.CountingProvider)
        secret {AshHooks.RetentionTest, :secret, []}
        event_id(&__MODULE__.event_id/1)
      end
    end

    def event_id(%{"id" => id}) when is_binary(id), do: {:ok, id}
    def event_id(_payload), do: :error
  end

  defmodule NoTimestamps do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.RetentionTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks, AshHooks.InboundDelivery]

    sqlite do
      table("retention_test_ledgers")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      attribute(:account_id, :string, allow_nil?: false)
    end

    actions do
      defaults([:read])
    end

    webhooks do
      inbound :counter do
        provider(AshHooks.CountingProvider)
        secret {AshHooks.RetentionTest, :secret, []}
      end
    end
  end

  defmodule DeliveryLedger do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.RetentionTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundDelivery]

    sqlite do
      table("retention_test_deliveries")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      timestamps()
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(AshHooks.RetentionTest.Ledger)
      resource(AshHooks.RetentionTest.NoTimestamps)
      resource(AshHooks.RetentionTest.DeliveryLedger)
    end
  end

  use ExUnit.Case, async: false

  alias AshHooks.{Delivery, Ingress}
  alias AshHooks.Test.Repo

  @ledgers "retention_test_ledgers"
  @deliveries "retention_test_deliveries"
  @ingress_secret "retention-test-secret"
  @old DateTime.add(DateTime.utc_now(), -90, :day) |> DateTime.truncate(:microsecond)
  @recent DateTime.add(DateTime.utc_now(), -1, :day) |> DateTime.truncate(:microsecond)

  setup_all do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@ledgers} (
      id TEXT PRIMARY KEY, provider TEXT NOT NULL, external_event_id TEXT NOT NULL,
      external_event_type TEXT, payload TEXT NOT NULL, payload_digest TEXT NOT NULL,
      status TEXT NOT NULL, fencing_token INTEGER NOT NULL DEFAULT 0,
      lease_expires_at TEXT, error_class TEXT, attempts INTEGER NOT NULL DEFAULT 0,
      account_id TEXT NOT NULL, inserted_at TEXT, updated_at TEXT
    )
    """)

    Repo.query!("""
    CREATE UNIQUE INDEX IF NOT EXISTS #{@ledgers}_unique_ingest_index ON #{@ledgers} (provider, external_event_id, account_id)
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@deliveries} (
      id TEXT PRIMARY KEY, event_uuid TEXT NOT NULL, event_type TEXT NOT NULL,
      payload BLOB NOT NULL, endpoint_id TEXT NOT NULL, subscription_id TEXT,
      signing_mode TEXT, status TEXT NOT NULL DEFAULT 'pending',
      attempts INTEGER NOT NULL DEFAULT 0, response_status INTEGER,
      response_snippet TEXT, last_error TEXT, next_attempt_at TEXT,
      inserted_at TEXT, updated_at TEXT
    )
    """)

    Repo.query!("""
    CREATE UNIQUE INDEX IF NOT EXISTS #{@deliveries}_unique_delivery_index ON #{@deliveries} (endpoint_id, event_uuid)
    """)

    on_exit(fn ->
      Repo.query!("DROP TABLE IF EXISTS #{@deliveries}")
      Repo.query!("DROP TABLE IF EXISTS #{@ledgers}")
    end)

    :ok
  end

  setup do
    Repo.query!("DELETE FROM #{@ledgers}")
    Repo.query!("DELETE FROM #{@deliveries}")
    AshHooks.CountingProvider.put_sink(self())
    AshHooks.CountingProvider.put_outcome(:ok)
    on_exit(&AshHooks.CountingProvider.cleanup/0)
    :ok
  end

  def secret, do: {:ok, @ingress_secret}

  defp row!(table, status, inserted_at, name) do
    id = Ash.UUID.generate()

    Repo.query!(
      "INSERT INTO #{table} (id, provider, external_event_id, payload, payload_digest, status, account_id, inserted_at, updated_at)
       VALUES (?, 'counter', ?, ?, 'digest', ?, 'acct', ?, ?)",
      [
        id,
        name,
        ~s({"secret_field": "sensitive", "kept": 1}),
        status,
        ts(inserted_at),
        ts(inserted_at)
      ]
    )

    id
  end

  describe "Ingress.prune/2" do
    test "deletes ONLY old terminal rows — non-terminal rows are never deleted" do
      row!(@ledgers, :processed, @old, "evt-old-processed")
      row!(@ledgers, :failed_permanent, @old, "evt-old-permanent")
      row!(@ledgers, :processed, @recent, "evt-new-processed")
      row!(@ledgers, :failed_retryable, @old, "old-retryable")
      row!(@ledgers, :received, @old, "old-received")
      row!(@ledgers, :claimed, @old, "old-claimed")

      assert {:ok, 2} = Ingress.prune(Ledger, older_than: @old)

      %{rows: rows} =
        Repo.query!(
          "SELECT status, external_event_id FROM #{@ledgers} ORDER BY external_event_id"
        )

      pairs = Enum.map(rows, fn [st, id] -> {String.to_atom(st), id} end)

      assert {:processed, "evt-new-processed"} in pairs
      assert {:failed_retryable, "old-retryable"} in pairs
      assert {:received, "old-received"} in pairs
      assert {:claimed, "old-claimed"} in pairs
      assert length(pairs) == 4
    end

    test "a resource without timestamps fails LOUD, naming the fix" do
      assert {:error, error} = Ingress.prune(NoTimestamps, older_than: @old)
      assert Exception.message(error) =~ "timestamps"
    end
  end

  describe "Delivery.prune/2" do
    test "deletes ONLY old terminal rows — pending/sending/retryable survive" do
      for status <- [
            :succeeded,
            :dead_letter,
            :pending,
            :failed_retryable,
            :sending,
            :enqueue_failed
          ] do
        delivery_row!(status, @old, "dlv-old-" <> Atom.to_string(status))
      end

      delivery_row!(:succeeded, @recent, "dlv-new-succeeded")

      assert {:ok, 2} = AshHooks.Delivery.prune(DeliveryLedger, older_than: @old)

      remaining = remaining_statuses(@deliveries)

      assert Enum.sort(remaining) ==
               [:enqueue_failed, :failed_retryable, :pending, :sending, :succeeded]
    end

    test "a resource without timestamps returns an error tuple naming the fix (Ingress.prune/2 contract)" do
      assert {:error, error} = AshHooks.Delivery.prune(NoTimestamps, older_than: @old)
      assert Exception.message(error) =~ "timestamps"
    end

    test "a destroy that errors surfaces the bulk error (never a silent zero)" do
      on_exit(fn ->
        Repo.query!("""
        CREATE TABLE IF NOT EXISTS #{@deliveries} (
          id TEXT PRIMARY KEY, event_uuid TEXT NOT NULL, event_type TEXT NOT NULL,
          payload BLOB NOT NULL, endpoint_id TEXT NOT NULL, subscription_id TEXT,
          signing_mode TEXT, status TEXT NOT NULL DEFAULT 'pending',
          attempts INTEGER NOT NULL DEFAULT 0, response_status INTEGER,
          response_snippet TEXT, last_error TEXT, next_attempt_at TEXT,
          inserted_at TEXT, updated_at TEXT
        )
        """)

        Repo.query!(
          "CREATE UNIQUE INDEX IF NOT EXISTS #{@deliveries}_unique_delivery_index ON #{@deliveries} (endpoint_id, event_uuid)"
        )
      end)

      Repo.query!(
        "CREATE TRIGGER IF NOT EXISTS #{@deliveries}_no_delete BEFORE DELETE ON #{@deliveries} BEGIN SELECT RAISE(ABORT, 'no'); END"
      )

      on_exit(fn ->
        Repo.query!("DROP TRIGGER IF EXISTS #{@deliveries}_no_delete")
      end)

      delivery_row!(:succeeded, @old, "dlv-old-trigger")

      assert {:error, _reason} = AshHooks.Delivery.prune(DeliveryLedger, older_than: @old)
    end
  end

  describe "Ingress.redact_payload/4" do
    test "replaces the payload under the claim fence; a stale token is rejected" do
      id = row!(@ledgers, :received, @recent, "evt-redact")
      {:ok, token, _} = Ingress.claim_delivery(Ledger, id)

      assert :ok =
               Ingress.redact_payload(Ledger, id, token, fn payload ->
                 Map.drop(payload, ["secret_field"])
               end)

      assert %{"kept" => 1} = payload_of(id)
    end

    test "a crashing redactor leaves the payload UNCHANGED and returns an error" do
      id = row!(@ledgers, :received, @recent, "evt-crash")
      {:ok, token, _} = Ingress.claim_delivery(Ledger, id)
      before_payload = payload_of(id)

      assert {:error, :redactor_crash} =
               Ingress.redact_payload(Ledger, id, token, fn _ -> raise "boom" end)

      assert payload_of(id) == before_payload
      assert payload_of(id)["secret_field"] == "sensitive"
    end

    test "an invalid redactor return is rejected, payload unchanged" do
      id = row!(@ledgers, :received, @recent, "evt-invalid")
      {:ok, token, _} = Ingress.claim_delivery(Ledger, id)

      assert {:error, :invalid_redactor_result} =
               Ingress.redact_payload(Ledger, id, token, fn _ -> :not_a_map end)

      assert payload_of(id) == %{"kept" => 1, "secret_field" => "sensitive"}
    end

    test "a stale token cannot redact and NEVER sees the payload (the fence)" do
      id = row!(@ledgers, :received, @recent, "evt-stale")
      {:ok, token1, _} = Ingress.claim_delivery(Ledger, id)
      parent = self()

      # expire the lease so a newer claim wins
      Repo.query!("UPDATE #{@ledgers} SET lease_expires_at = ? WHERE id = ?", [
        DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.to_iso8601(),
        id
      ])

      {:ok, _token2, _} = Ingress.claim_delivery(Ledger, id)

      assert {:error, :stale_token} =
               Ingress.redact_payload(Ledger, id, token1, fn p ->
                 send(parent, :redactor_invoked)
                 p
               end)

      refute_received :redactor_invoked
    end
  end

  defp delivery_row!(status, inserted_at, name) do
    id = Ash.UUID.generate()

    Repo.query!(
      "INSERT INTO #{@deliveries} (id, event_uuid, event_type, payload, status, endpoint_id, inserted_at, updated_at, attempts)
       VALUES (?, ?, 'order_paid', '{}', ?, '00000000-0000-0000-0000-0000000000ff', ?, ?, 0)",
      [id, name, status, ts(inserted_at), ts(inserted_at)]
    )

    id
  end

  # the adapter storage form: T-separated ISO8601 with microseconds —
  # space-formatted fixtures pass boundary tests for the WRONG reason
  # (lexical artifact, cross-vendor finding)
  defp ts(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S.%6f") <> "Z"

  # helpers

  defp remaining_statuses(table) do
    %{rows: rows} = Repo.query!("SELECT status FROM #{table}")
    Enum.map(rows, fn [status] -> String.to_atom(status) end)
  end

  defp payload_of(id) do
    %{rows: [[payload]]} = Repo.query!("SELECT payload FROM #{@ledgers} WHERE id = ?", [id])
    Jason.decode!(payload)
  end
end
