defmodule AshHooks.InboundParityTest do
  @moduledoc """
  Inbound parity: query inbound deliveries by source, status, event type,
  and time range with keyset pagination; count received, duplicates
  ignored, failed verifications, and handler failures over a window; rotate
  an inbound source's secret with an overlap window (both keys verify
  until it ends); and pause a source so requests are refused and the
  provider retries.
  """

  defmodule Ledger do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.InboundParityTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks, AshHooks.InboundDelivery]

    sqlite do
      table("inbound_parity_ledgers")
      repo(AshHooks.Test.Repo)
    end

    inbound_delivery do
      scope_identity([:account_id])
      ingress_tracking(:on)
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
        secret {AshHooks.InboundParityTest, :secret, []}
        previous_secret({AshHooks.InboundParityTest, :previous_secret, []})
        event_id(&__MODULE__.event_id/1)
      end

      inbound :rotated_away do
        provider(AshHooks.CountingProvider)
        secret {AshHooks.InboundParityTest, :secret, []}
        event_id(&__MODULE__.event_id/1)
      end

      inbound :pausable do
        provider(AshHooks.CountingProvider)
        secret {AshHooks.InboundParityTest, :secret, []}
        paused({AshHooks.InboundParityTest, :paused?, []})
        event_id(&__MODULE__.event_id/1)
      end
    end

    def event_id(%{"id" => id}) when is_binary(id), do: {:ok, id}
    def event_id(_payload), do: :error
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(AshHooks.InboundParityTest.Ledger)
    end
  end

  use ExUnit.Case, async: false

  alias AshHooks.Test.Repo

  @ledger "inbound_parity_ledgers"
  @current "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))
  @old "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))

  setup_all do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@ledger} (
      id TEXT PRIMARY KEY, provider TEXT NOT NULL, external_event_id TEXT NOT NULL,
      external_event_type TEXT, payload TEXT, payload_digest TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'received', fencing_token INTEGER NOT NULL DEFAULT 0,
      lease_expires_at TEXT, error_class TEXT, attempts INTEGER NOT NULL DEFAULT 0,
      duplicates INTEGER NOT NULL DEFAULT 0,
      account_id TEXT NOT NULL,
      inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@ledger}_unique_ingest_index ON #{@ledger} (provider, external_event_id, account_id)"
    )

    on_exit(fn ->
      Repo.query!("DROP TABLE IF EXISTS #{@ledger}")
      AshHooks.CountingProvider.cleanup()
      Application.delete_env(:ash_hooks, :inbound_parity_paused)
    end)

    :ok
  end

  setup do
    Repo.query!("DELETE FROM #{@ledger}")
    AshHooks.CountingProvider.put_sink(self())
    AshHooks.CountingProvider.put_outcome(:ok)
    Application.delete_env(:ash_hooks, :inbound_parity_paused)
    :ok
  end

  def secret, do: {:ok, @current}
  def previous_secret, do: {:ok, @old}
  def paused?, do: Application.get_env(:ash_hooks, :inbound_parity_paused, false)

  defp signed_body(source, id, secret) do
    body = Jason.encode!(%{"id" => id, "type" => "created"})

    signature =
      :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)

    {body, %{signature: signature, scope: %{"account_id" => "acct-1"}}}
  end

  defp ingest_ok(id), do: signed_body(:counter, id, @current)

  test "list queries by source, status, event type, and time range (keyset)" do
    for i <- 1..3 do
      {body, ctx} = ingest_ok("evt_parity_#{i}")
      {:ok, :created, _} = AshHooks.Ingress.ingest(Ledger, :counter, body, ctx)
    end

    {:ok, %{records: page, next_cursor: cursor}} =
      AshHooks.Ingress.list(Ledger, source: :counter, limit: 2)

    assert length(page) == 2
    assert is_binary(cursor)

    {:ok, %{records: rest, next_cursor: nil}} =
      AshHooks.Ingress.list(Ledger, source: :counter, limit: 2, after: cursor)

    assert length(rest) == 1

    assert {:ok, %{records: []}} =
             AshHooks.Ingress.list(Ledger, source: :rotated_away)

    assert {:ok, %{records: []}} =
             AshHooks.Ingress.list(Ledger, status: [:failed_permanent])

    assert {:ok, %{records: []}} =
             AshHooks.Ingress.list(Ledger,
               event_type: "created",
               from: DateTime.add(DateTime.utc_now(), 60, :second)
             )
  end

  test "the pause/rotation/tracking shapes cover their arms" do
    # app_env pause source (on + off) and an invalid source shape
    # (resolved via a runtime-compiled declaration in transformers_test
    # style — here: the {m,f,a} arm)
    Application.put_env(:ash_hooks, :inbound_parity_paused, false)
    {body, ctx} = signed_body(:pausable, "evt_pause_off", @current)
    {:ok, :created, _} = AshHooks.Ingress.ingest(Ledger, :pausable, body, ctx)

    # fn-shaped previous_secret resolution arms (via a second ledger? no —
    # direct: the previous secret arm with a bad key source collapses to
    # the current-key error)
    tampered = Jason.encode!(%{"id" => "evt_prev_bad", "type" => "created"})

    bad_sig =
      :crypto.mac(:hmac, :sha256, "neither-key", tampered) |> Base.encode16(case: :lower)

    assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
             AshHooks.Ingress.ingest(Ledger, :counter, tampered, %{
               signature: bad_sig,
               scope: %{"account_id" => "acct-1"}
             })

    # an empty window counts zeros; a read failure counts zeros (never a crash)
    assert {:ok, counts} =
             AshHooks.Ingress.counts(Ledger,
               from: DateTime.add(DateTime.utc_now(), 60, :second),
               to: DateTime.add(DateTime.utc_now(), 120, :second)
             )

    assert counts.received == 0

    # list without timestamps names the error (the no-ts resource arm)
    source = """
    defmodule AshHooks.NoTsLedger do
      use Ash.Resource,
        domain: AshHooks.InboundParityTest.Domain,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshHooks, AshHooks.InboundDelivery]

      attributes do
        attribute(:account_id, :string, allow_nil?: false)
      end

      actions do
        defaults([:read])
      end

      webhooks do
        inbound :counter do
          provider(AshHooks.CountingProvider)
          secret {AshHooks.InboundParityTest, :secret, []}
          event_id(&AshHooks.InboundParityTest.Ledger.event_id/1)
        end
      end
    end
    """

    modules = Code.compile_string(source)
    assert {AshHooks.NoTsLedger, _beam} = List.keyfind(modules, AshHooks.NoTsLedger, 0)

    assert {:error, %AshHooks.Errors.Unknown.UnknownError{}} =
             AshHooks.Ingress.list(AshHooks.NoTsLedger)

    assert {:error, %AshHooks.Errors.Unknown.UnknownError{}} =
             AshHooks.Ingress.counts(AshHooks.NoTsLedger)
  after
    _ = :code.purge(AshHooks.NoTsLedger)
    _ = :code.delete(AshHooks.NoTsLedger)
  end

  test "every pause and previous-secret source shape resolves" do
    # fn/0 pause: paused via a zero-arity function
    Application.put_env(:ash_hooks, :inbound_parity_paused, true)
    {body, ctx} = signed_body(:fn_paused, "evt_fn_paused", @current)

    source = """
    defmodule AshHooks.FnPausedDomain do
      use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

      resources do
        resource(AshHooks.FnPausedLedger)
      end
    end

    defmodule AshHooks.FnPausedLedger do
      use Ash.Resource,
        domain: AshHooks.FnPausedDomain,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshHooks, AshHooks.InboundDelivery]

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
        inbound :fn_paused do
          provider(AshHooks.CountingProvider)
          secret {AshHooks.InboundParityTest, :secret, []}
          paused fn -> Application.get_env(:ash_hooks, :inbound_parity_paused, false) end
          event_id(&AshHooks.InboundParityTest.Ledger.event_id/1)
        end

        inbound :appenv_paused do
          provider(AshHooks.CountingProvider)
          secret {AshHooks.InboundParityTest, :secret, []}
          paused {:app_env, [:ash_hooks, :inbound_parity_paused]}
          event_id(&AshHooks.InboundParityTest.Ledger.event_id/1)
        end

        inbound :fn_previous do
          provider(AshHooks.CountingProvider)
          secret {AshHooks.InboundParityTest, :secret, []}
          previous_secret fn -> {:ok, AshHooks.InboundParityTest.previous_secret_value()} end
          event_id(&AshHooks.InboundParityTest.Ledger.event_id/1)
        end

        inbound :bad_previous do
          provider(AshHooks.CountingProvider)
          secret {AshHooks.InboundParityTest, :secret, []}
          previous_secret {:app_env, [:ash_hooks, :inbound_parity_previous]}
          event_id(&AshHooks.InboundParityTest.Ledger.event_id/1)
        end

        inbound :offtree_previous do
          provider(AshHooks.CountingProvider)
          secret {AshHooks.InboundParityTest, :secret, []}
          previous_secret {:app_env, [:ash_hooks, :inbound_parity_nested, :secret]}
          event_id(&AshHooks.InboundParityTest.Ledger.event_id/1)
        end

        inbound :arity_previous do
          provider(AshHooks.CountingProvider)
          secret {AshHooks.InboundParityTest, :secret, []}
          previous_secret fn _tenant -> {:ok, "whsec_zzz"} end
          event_id(&AshHooks.InboundParityTest.Ledger.event_id/1)
        end

        inbound :arity_paused do
          provider(AshHooks.CountingProvider)
          secret {AshHooks.InboundParityTest, :secret, []}
          paused fn _tenant -> true end
          event_id(&AshHooks.InboundParityTest.Ledger.event_id/1)
        end
      end
    end
    """

    modules = Code.compile_string(source)
    assert {AshHooks.FnPausedLedger, _beam} = List.keyfind(modules, AshHooks.FnPausedLedger, 0)
    _ = List.keyfind(modules, AshHooks.FnPausedDomain, 0)

    # fn pause refuses
    assert {:error, :source_paused} =
             AshHooks.Ingress.ingest(AshHooks.FnPausedLedger, :fn_paused, body, ctx)

    # app_env pause refuses while true, admits when false
    Application.put_env(:ash_hooks, :inbound_parity_paused, true)

    IO.inspect(AshHooks.Info.inbound(AshHooks.FnPausedLedger, :appenv_paused).paused,
      label: "PAUSED OPT"
    )

    {env_body, env_ctx} = signed_body(:appenv_paused, "evt_env_paused", @current)

    assert {:error, :source_paused} =
             AshHooks.Ingress.ingest(AshHooks.FnPausedLedger, :appenv_paused, env_body, env_ctx)

    Application.delete_env(:ash_hooks, :inbound_parity_paused)

    assert {:ok, :created, _} =
             AshHooks.Ingress.ingest(AshHooks.FnPausedLedger, :appenv_paused, env_body, env_ctx)

    # fn previous_secret verifies the OLD key
    {old_body, old_ctx} = signed_body(:fn_previous, "evt_fn_previous", @old)

    {:ok, :created, _} =
      AshHooks.Ingress.ingest(AshHooks.FnPausedLedger, :fn_previous, old_body, old_ctx)

    # an app_env previous that resolves nothing collapses to the
    # current-key failure
    {bad_body, bad_ctx} = signed_body(:bad_previous, "evt_bad_previous", @old)

    assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
             AshHooks.Ingress.ingest(AshHooks.FnPausedLedger, :bad_previous, bad_body, bad_ctx)

    # a from+to list window composes (both bounds at once)
    {:ok, %{records: [_]}} =
      AshHooks.Ingress.list(AshHooks.FnPausedLedger,
        source: :appenv_paused,
        from: DateTime.add(DateTime.utc_now(), -60, :second),
        to: DateTime.add(DateTime.utc_now(), 60, :second)
      )

    # an off-tree env walk (a non-keyword intermediate) resolves nothing:
    # the current-key failure stands
    Application.put_env(:ash_hooks, :inbound_parity_nested, "not-a-keyword")
    {tree_body, tree_ctx} = signed_body(:offtree_previous, "evt_offtree", @old)

    assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
             AshHooks.Ingress.ingest(
               AshHooks.FnPausedLedger,
               :offtree_previous,
               tree_body,
               tree_ctx
             )

    # a 1-arity previous-secret fn (a shape the source validator admits)
    # is not a supported previous source — collapses to the current key
    {arity_body, arity_ctx} = signed_body(:arity_previous, "evt_arity_prev", @old)

    assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
             AshHooks.Ingress.ingest(
               AshHooks.FnPausedLedger,
               :arity_previous,
               arity_body,
               arity_ctx
             )

    # a 1-arity pause fn resolves not-paused (the unsupported shape fails
    # OPEN on pause — deliveries continue)
    {open_body, open_ctx} = signed_body(:arity_paused, "evt_arity_paused", @current)

    {:ok, :created, _} =
      AshHooks.Ingress.ingest(AshHooks.FnPausedLedger, :arity_paused, open_body, open_ctx)

    # list with a to-bound alone composes; a failed window read counts zeros
    {:ok, %{records: [_]}} =
      AshHooks.Ingress.list(AshHooks.FnPausedLedger,
        source: :appenv_paused,
        to: DateTime.add(DateTime.utc_now(), 60, :second)
      )

    Repo.query!("DROP TABLE #{@ledger}")

    assert {:ok, %{received: 0}} =
             AshHooks.Ingress.counts(Ledger, from: DateTime.add(DateTime.utc_now(), -60, :second))
  after
    recreate_ledger!()

    for mod <- [AshHooks.FnPausedLedger, AshHooks.FnPausedDomain] do
      _ = :code.purge(mod)
      _ = :code.delete(mod)
    end

    Application.delete_env(:ash_hooks, :inbound_parity_paused)
  end

  def previous_secret_value do
    @old
  end

  test "counts over a window: received, duplicates, failed verification, handler failures" do
    {body, ctx} = ingest_ok("evt_counts_ok")
    {:ok, :created, _} = AshHooks.Ingress.ingest(Ledger, :counter, body, ctx)

    # a duplicate: the provider retries the same signed event
    {:ok, :duplicate, _} = AshHooks.Ingress.ingest(Ledger, :counter, body, ctx)

    # a failed verification: tampered signature
    tampered_body = Jason.encode!(%{"id" => "evt_bad_sig", "type" => "created"})

    tampered_sig =
      :crypto.mac(:hmac, :sha256, "wrong", tampered_body) |> Base.encode16(case: :lower)

    assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
             AshHooks.Ingress.ingest(Ledger, :counter, tampered_body, %{
               signature: tampered_sig,
               scope: %{"account_id" => "acct-1"}
             })

    # a handler failure (a retryable handler error leaves a failed row)
    AshHooks.CountingProvider.put_outcome({:error, :retry, "boom"})
    {fail_body, fail_ctx} = ingest_ok("evt_counts_fail")
    _ = AshHooks.Ingress.ingest(Ledger, :counter, fail_body, fail_ctx)

    assert {:ok, counts} =
             AshHooks.Ingress.counts(Ledger,
               from: DateTime.add(DateTime.utc_now(), -60, :second)
             )

    assert counts.received == 2
    assert counts.duplicates == 1
    assert counts.failed_verification == 1
    assert counts.handler_failures == 1
    assert counts.processed == 1
  end

  test "a rotated source verifies against BOTH keys during the overlap" do
    # the OLD key still verifies on the source carrying previous_secret
    {old_body, old_ctx} = signed_body(:counter, "evt_overlap_old", @old)
    {:ok, :created, _} = AshHooks.Ingress.ingest(Ledger, :counter, old_body, old_ctx)

    # and so does the CURRENT key
    {new_body, new_ctx} = signed_body(:counter, "evt_overlap_new", @current)
    {:ok, :created, _} = AshHooks.Ingress.ingest(Ledger, :counter, new_body, new_ctx)

    # without the previous configured, the OLD key is refused
    {away_body, away_ctx} = signed_body(:rotated_away, "evt_overlap_away", @old)

    assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
             AshHooks.Ingress.ingest(Ledger, :rotated_away, away_body, away_ctx)
  end

  test "a paused source refuses requests so the provider retries" do
    Application.put_env(:ash_hooks, :inbound_parity_paused, true)

    {body, ctx} = signed_body(:pausable, "evt_paused", @current)

    assert {:error, :source_paused} = AshHooks.Ingress.ingest(Ledger, :pausable, body, ctx)

    # nothing was written or handled
    assert Repo.query!("SELECT COUNT(*) FROM #{@ledger}").rows == [[0]]
    refute_received {:handled, _, _}

    # unpausing resumes immediately
    Application.delete_env(:ash_hooks, :inbound_parity_paused)
    {:ok, :created, _} = AshHooks.Ingress.ingest(Ledger, :pausable, body, ctx)
    assert Repo.query!("SELECT COUNT(*) FROM #{@ledger}").rows == [[1]]
  end

  defp recreate_ledger! do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@ledger} (
      id TEXT PRIMARY KEY, provider TEXT NOT NULL, external_event_id TEXT NOT NULL,
      external_event_type TEXT, payload TEXT, payload_digest TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'received', fencing_token INTEGER NOT NULL DEFAULT 0,
      lease_expires_at TEXT, error_class TEXT, attempts INTEGER NOT NULL DEFAULT 0,
      duplicates INTEGER NOT NULL DEFAULT 0,
      account_id TEXT NOT NULL,
      inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@ledger}_unique_ingest_index ON #{@ledger} (provider, external_event_id, account_id)"
    )
  end
end
