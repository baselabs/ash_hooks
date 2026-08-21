defmodule AshHooks.IngressTest do
  @moduledoc """
  The fenced ingress machine on a REAL sqlite unique index (probe
  2026-08-21: this is the substrate that actually enforces identity
  uniqueness and conditional-update atomicity). Covers the sync pipeline,
  the fail-closed floors, and the ACCEPT tripwires: crash windows re-drive
  (never a no-op), the stale owner cannot mark, and concurrent identical
  deliveries process exactly once.
  """

  defmodule Ledger do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.IngressTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks, AshHooks.InboundDelivery]

    sqlite do
      table("ingress_test_ledgers")
      repo(AshHooks.Test.Repo)
    end

    inbound_delivery do
      scope_identity([:account_id])
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
        secret {AshHooks.IngressTest, :secret, []}
        event_id(&__MODULE__.event_id/1)
      end

      inbound :hashback do
        provider(AshHooks.CountingProvider)
        secret {AshHooks.IngressTest, :secret, []}
      end

      inbound :secretless do
        provider(AshHooks.CountingProvider)
        secret {AshHooks.IngressTest, :no_secret, []}
      end
    end

    def event_id(%{"id" => id}) when is_binary(id), do: {:ok, id}
    def event_id(_payload), do: :error
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(AshHooks.IngressTest.Ledger)
    end
  end

  use ExUnit.Case, async: false

  alias AshHooks.CountingProvider
  alias AshHooks.Errors.Invalid
  alias AshHooks.Ingress
  alias AshHooks.Test.Repo

  @table "ingress_test_ledgers"
  @secret "test-secret"

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
      attempts INTEGER NOT NULL DEFAULT 0,
      account_id TEXT NOT NULL
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@table}_unique_ingest_index ON #{@table} (provider, external_event_id, account_id)"
    )

    on_exit(fn ->
      Repo.query!("DROP TABLE IF EXISTS #{@table}")
    end)

    :ok
  end

  setup do
    Repo.query!("DELETE FROM #{@table}")
    CountingProvider.put_sink(self())
    CountingProvider.put_outcome(:ok)
    on_exit(&CountingProvider.cleanup/0)
    :ok
  end

  def secret, do: {:ok, @secret}
  def no_secret, do: {:error, :no_webhook_secret}

  defp sign(body), do: :crypto.mac(:hmac, :sha256, @secret, body) |> Base.encode16(case: :lower)

  # flip to a DIFFERENT char — replacing with a constant can no-op when the
  # original already equals it (first-char tamper trap).
  defp flip_first_char(<<first, rest::binary>>) do
    replacement = if first == ?f, do: ?0, else: ?f
    <<replacement, rest::binary>>
  end

  defp ctx(body, overrides \\ []) do
    Map.merge(
      %{
        signature: sign(body),
        headers: %{},
        scope: %{"account_id" => "acct-1"}
      },
      Map.new(overrides)
    )
  end

  defp body(id \\ "evt_1") do
    Jason.encode!(%{"id" => id, "type" => "counted", "n" => 1})
  end

  defp rows(provider \\ :counter) do
    require Ash.Query

    Ash.Query.filter(Ledger, provider == ^provider)
    |> Ash.read!(authorize?: false)
  end

  defp expire_lease(external_event_id) do
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

    Repo.query!(
      "UPDATE #{@table} SET lease_expires_at = ? WHERE external_event_id = ?",
      [DateTime.to_iso8601(past), external_event_id]
    )
  end

  defp stranded_received_row(id \\ "evt_strand") do
    # The post-ingest, pre-claim crash state: a persisted :received row no
    # process is driving.
    raw = body(id)

    {:ok, row} =
      Ash.create(
        Ledger,
        %{
          id: Ash.UUID.generate(),
          provider: :counter,
          external_event_id: id,
          external_event_type: "counted",
          payload: Jason.decode!(raw),
          payload_digest: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower),
          account_id: "acct-1"
        },
        action: :ingest,
        authorize?: false
      )

    row
  end

  describe "sync pipeline" do
    test "a verified delivery is persisted, claimed, handled, and marked processed" do
      raw = body()

      assert {:ok, :created, delivery} = Ingress.ingest(Ledger, :counter, raw, ctx(raw))

      assert delivery.status == :processed
      assert delivery.external_event_id == "evt_1"
      assert delivery.external_event_type == "counted"
      assert delivery.payload == %{"id" => "evt_1", "type" => "counted", "n" => 1}
      assert delivery.payload_digest == :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
      assert delivery.fencing_token == 1
      assert delivery.attempts == 1
      assert is_nil(delivery.error_class)

      assert_receive {:handled, :counted}
      refute_received {:handled, _}

      assert [%{status: :processed}] = rows()
    end

    test "a redelivery of a processed event is a no-op duplicate" do
      raw = body()

      assert {:ok, :created, _} = Ingress.ingest(Ledger, :counter, raw, ctx(raw))
      assert {:ok, :duplicate, delivery} = Ingress.ingest(Ledger, :counter, raw, ctx(raw))

      assert delivery.status == :processed
      assert_receive {:handled, :counted}
      refute_received {:handled, _}

      assert [%{attempts: 1}] = rows()
    end

    test "an invalid signature fails closed with no ledger write" do
      raw = body()

      assert {:error, %Invalid.InvalidSignature{}} =
               Ingress.ingest(
                 Ledger,
                 :counter,
                 raw,
                 ctx(raw, signature: flip_first_char(sign(raw)))
               )

      assert rows() == []
      refute_received {:handled, _}
    end

    test "a missing secret fails closed with no ledger write and no verification" do
      raw = body()

      assert {:error, %Invalid.NoWebhookSecret{}} =
               Ingress.ingest(Ledger, :secretless, raw, ctx(raw))

      assert rows(:secretless) == []
      refute_received {:handled, _}
    end

    test "a missing signature header fails closed as a tuple, never a crash" do
      raw = body("evt_nosig")

      assert {:error, %Invalid.InvalidSignature{}} =
               Ingress.ingest(Ledger, :counter, raw, ctx(raw, %{signature: nil}))

      assert rows() == []
      refute_received {:handled, _}
    end

    test "a missing raw body never runs" do
      assert {:error, %Invalid.MalformedPayload{}} =
               Ingress.ingest(Ledger, :counter, nil, ctx("whatever"))

      assert rows() == []
      refute_received {:handled, _}
    end

    test "a non-JSON body is recorded as permanently malformed, never handled" do
      raw = "not json at all"

      assert {:ok, :created, delivery} = Ingress.ingest(Ledger, :counter, raw, ctx(raw))

      assert delivery.status == :failed_permanent
      assert delivery.error_class == "malformed_payload"
      assert delivery.payload == %{}
      refute_received {:handled, _}
    end

    test "an unknown event type is recorded as permanently unknown, never handled" do
      raw = Jason.encode!(%{"id" => "evt_unknown", "type" => "never_a_real_atom_x7q"})

      assert {:ok, :created, delivery} = Ingress.ingest(Ledger, :counter, raw, ctx(raw))

      assert delivery.status == :failed_permanent
      assert delivery.error_class == "unknown_event_type"
      refute_received {:handled, _}
    end

    test "a retryable handler failure is recorded and re-driven by redelivery" do
      CountingProvider.put_outcome({:error, :retry, "boom"})
      raw = body("evt_retry")

      assert {:ok, :created, delivery} = Ingress.ingest(Ledger, :counter, raw, ctx(raw))
      assert delivery.status == :failed_retryable
      assert delivery.error_class =~ "boom"

      assert_receive {:handled, :counted}
      CountingProvider.put_outcome(:ok)

      assert {:ok, :duplicate, delivery} = Ingress.ingest(Ledger, :counter, raw, ctx(raw))
      assert delivery.status == :processed

      assert_receive {:handled, :counted}
      refute_received {:handled, _}
      assert [%{attempts: 2, status: :processed}] = rows()
    end

    test "a permanent handler failure is terminal for redelivery" do
      CountingProvider.put_outcome({:error, :permanent, "poison"})
      raw = body("evt_poison")

      assert {:ok, :created, delivery} = Ingress.ingest(Ledger, :counter, raw, ctx(raw))
      assert delivery.status == :failed_permanent
      assert delivery.error_class =~ "poison"

      assert_receive {:handled, :counted}
      CountingProvider.put_outcome(:ok)

      assert {:ok, :duplicate, delivery} = Ingress.ingest(Ledger, :counter, raw, ctx(raw))
      assert delivery.status == :failed_permanent
      refute_received {:handled, _}
    end

    test "a provider without ids uses the deterministic content-hash identity" do
      raw = Jason.encode!(%{"type" => "counted", "blob" => :rand.uniform(999)})

      digest = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

      assert {:ok, :created, delivery} = Ingress.ingest(Ledger, :hashback, raw, ctx(raw))
      assert delivery.external_event_id == digest

      assert {:ok, :duplicate, _} = Ingress.ingest(Ledger, :hashback, raw, ctx(raw))
      assert [%{external_event_id: ^digest}] = rows(:hashback)
    end
  end

  describe "crash windows (ACCEPT: kill between steps re-drives, never a no-op)" do
    test "a stranded :received row (crash after ingest, before claim) is re-driven" do
      stranded = stranded_received_row()

      refute_received {:handled, _}
      raw = body("evt_strand")

      assert {:ok, :duplicate, delivery} = Ingress.ingest(Ledger, :counter, raw, ctx(raw))

      assert delivery.status == :processed
      assert delivery.id == stranded.id
      assert_receive {:handled, :counted}
      refute_received {:handled, _}
      assert [%{status: :processed, attempts: 1}] = rows()
    end

    test "a stranded :claimed row with an unexpired lease is not double-driven" do
      stranded = stranded_received_row("evt_lease")
      {:ok, _token, _} = Ingress.claim_delivery(Ledger, stranded.id)

      raw = body("evt_lease")

      assert {:ok, :duplicate, delivery} = Ingress.ingest(Ledger, :counter, raw, ctx(raw))

      assert delivery.status == :claimed
      refute_received {:handled, _}
    end

    test "a stranded :claimed row whose lease EXPIRED is re-driven exactly once" do
      stranded = stranded_received_row("evt_expired")
      {:ok, _token, _} = Ingress.claim_delivery(Ledger, stranded.id)
      expire_lease("evt_expired")

      raw = body("evt_expired")

      assert {:ok, :duplicate, delivery} = Ingress.ingest(Ledger, :counter, raw, ctx(raw))

      assert delivery.status == :processed
      assert_receive {:handled, :counted}
      refute_received {:handled, _}
      assert [%{status: :processed, fencing_token: 2, attempts: 2}] = rows()
    end
  end

  describe "stale owner (ACCEPT: an expired-lease owner cannot mark)" do
    test "the prior token cannot mark, fail, or renew after a newer claim" do
      row = stranded_received_row("evt_fence")
      {:ok, token1, _} = Ingress.claim_delivery(Ledger, row.id)
      expire_lease("evt_fence")
      {:ok, token2, _} = Ingress.claim_delivery(Ledger, row.id)
      assert token2 > token1

      assert {:error, :stale_token} = Ingress.mark_processed(Ledger, row.id, token1)
      assert {:error, :stale_token} = Ingress.mark_failed(Ledger, row.id, token1, "late", false)
      assert {:error, :stale_token} = Ingress.renew(Ledger, row.id, token1)

      assert :ok = Ingress.mark_processed(Ledger, row.id, token2)
    end

    @tag :own_expiry
    test "the CURRENT token cannot mark once its own lease has expired" do
      row = stranded_received_row("evt_own_expiry")
      {:ok, token, _} = Ingress.claim_delivery(Ledger, row.id)
      expire_lease("evt_own_expiry")

      assert {:error, :stale_token} = Ingress.mark_processed(Ledger, row.id, token)
    end
  end

  describe "concurrent identical deliveries (ACCEPT: exactly one processes)" do
    @tag :concurrent_identical
    test "a true process race on the same delivery runs the handler once" do
      raw = body("evt_race")
      context = ctx(raw)
      parent = self()

      n = 4

      pids =
        for i <- 1..n do
          spawn(fn ->
            send(parent, {:ready, i})

            receive do
              :go -> :ok
            after
              10_000 -> exit(:no_go)
            end

            result =
              try do
                Ingress.ingest(Ledger, :counter, raw, context)
              rescue
                e -> {:crashed, Exception.format(:error, e)}
              end

            send(parent, {:result, result})
          end)
        end

      Enum.each(1..n, fn _ -> receive(do: ({:ready, _} -> :ok)) end)
      Enum.each(pids, &send(&1, :go))

      results =
        Enum.map(1..n, fn _ ->
          receive do
            {:result, result} -> result
          after
            15_000 -> {:timeout, :no_result}
          end
        end)

      created = Enum.count(results, &match?({:ok, :created, _}, &1))

      # Exactly one creator; every other racer is a clean duplicate or a
      # transient storage error (sqlite WAL can surface busy-lock errors to
      # losers under write contention — at-least-once semantics tolerate it;
      # the effect-once invariant below is what must hold unconditionally).
      assert created == 1

      assert Enum.all?(
               results,
               &(match?({:ok, :created, _}, &1) or match?({:ok, :duplicate, _}, &1) or
                   match?({:error, _}, &1))
             )

      assert_receive {:handled, :counted}

      # transient window, not settled state: wait for stragglers, then the
      # total must still be exactly one handler run
      Enum.each(1..(n - 1), fn _ ->
        receive do
          {:result, _} -> :ok
        after
          0 -> :ok
        end
      end)

      refute_received {:handled, _}

      assert [%{status: :processed, fencing_token: 1, attempts: 1}] = rows()
    end
  end

  describe "reaper" do
    test "expired leases are re-driven; unexpired and terminal rows are left alone" do
      expired = stranded_received_row("evt_reap_1")
      {:ok, _, _} = Ingress.claim_delivery(Ledger, expired.id)
      expire_lease("evt_reap_1")

      held = stranded_received_row("evt_reap_2")
      {:ok, _, _} = Ingress.claim_delivery(Ledger, held.id)

      assert {:ok, 1} = Ingress.reap(Ledger)

      assert_receive {:handled, :counted}
      refute_received {:handled, _}

      statuses = rows() |> Map.new(&{&1.external_event_id, &1.status})
      assert statuses["evt_reap_1"] == :processed
      assert statuses["evt_reap_2"] == :claimed
    end
  end
end
