Code.require_file("outbox_process.exs", __DIR__)
Code.require_file("outbox_resources.exs", __DIR__)

if Code.ensure_loaded?(Oban) do
  for {module, namespace} <- [
        {AshHooks.WorkerOutcomesSQLiteTest, AshHooks.OutboxFixtures.SQLite},
        {AshHooks.WorkerOutcomesPostgresTest, AshHooks.OutboxFixtures.Postgres}
      ] do
    defmodule module do
      use ExUnit.Case, async: false
      alias AshHooks.OutboxAcceptance, as: Cases
      @namespace namespace
      if @namespace == AshHooks.OutboxFixtures.Postgres, do: @moduletag(:postgres)

      setup_all do
        {:ok, Cases.setup(@namespace)}
      end

      setup f do
        Cases.clean(f)
        parent = self()
        handler = make_ref()

        :ok =
          :telemetry.attach_many(
            handler,
            [
              [:ash_hooks, :outbox, :claim],
              [:ash_hooks, :outbox, :result],
              [:ash_hooks, :delivery, :missing]
            ],
            fn name, measurements, metadata, _ ->
              send(parent, {:worker_outcome, name, measurements, metadata})
            end,
            nil
          )

        on_exit(fn -> :telemetry.detach(handler) end)
        {:ok, worker: Module.concat(f.namespace, :Worker)}
      end

      test "an absent publication cancels with exactly one missing claim event", f do
        id = Ash.UUID.generate()
        assert {:cancel, :publication_missing} = f.worker.perform(fanout_job(f, id))

        assert_receive {:worker_outcome, [:ash_hooks, :outbox, :claim], %{count: 1},
                        metadata}

        assert metadata == %{
                 event_uuid: id,
                 outcome: :missing,
                 reason: nil,
                 tenant: "tenant-a"
               }

        refute_received {:worker_outcome, _, _, _}
      end

      test "a parked publication cancels and a done publication completes visibly", f do
        for {state, result} <- [failed: {:cancel, :publication_failed}, done: :ok] do
          event = Cases.event()
          assert {:ok, :accepted} = Cases.publish(f, event)

          if state == :failed, do: Cases.set(f, event.id, format_version: 99)
          assert ^result = f.worker.perform(fanout_job(f, event.id))

          assert_receive {:worker_outcome, name, %{count: 1}, metadata}

          assert name == [:ash_hooks, :outbox, :claim]
          assert %{event_uuid: id, outcome: :claimed, reason: nil, tenant: "tenant-a"} = metadata

          assert_receive {:worker_outcome, [:ash_hooks, :outbox, :result], %{count: 1},
                          %{event_uuid: ^id, outcome: ^state, tenant: "tenant-a"}}

          assert id == event.id
          assert Cases.publication(f, event.id).state == state
          assert ^result = f.worker.perform(fanout_job(f, event.id))

          assert_receive {:worker_outcome, [:ash_hooks, :outbox, :claim], %{count: 1},
                          metadata}

          assert metadata == %{
                   event_uuid: id,
                   outcome: state,
                   reason: nil,
                   tenant: "tenant-a"
                 }

          refute_received {:worker_outcome, _, _, _}
        end
      end

      test "a busy publication completes its trigger and remains pending for the sweep", f do
        event = Cases.event()
        assert {:ok, :accepted} = Cases.publish(f, event)
        Cases.set(f, event.id, next_attempt_at: DateTime.add(DateTime.utc_now(), 60, :second))
        assert :ok = f.worker.perform(fanout_job(f, event.id))
        assert Cases.publication(f, event.id).state == :pending

        assert_receive {:worker_outcome, [:ash_hooks, :outbox, :claim], %{count: 1},
                        %{outcome: :busy, reason: nil, tenant: "tenant-a"}}

        refute_received {:worker_outcome, _, _, _}
      end

      test "invalid fanout event identities cancel before a read", f do
        for id <- [nil, "", 123, %{}] do
          assert {:cancel, :invalid_event} = f.worker.perform(fanout_job(f, id))
        end

        refute_received {:worker_outcome, _, _, _}
      end

      test "missing deliveries cancel and emit the job identity and resolved tenant", f do
        endpoint_id = Ash.UUID.generate()
        event_uuid = Ash.UUID.generate()
        key = %{"id" => Ash.UUID.generate()}

        for tenant <- ["tenant-a", "tenant-b"],
            identity <- [
              %{"endpoint_id" => endpoint_id, "event_uuid" => event_uuid},
              %{endpoint_id: endpoint_id, event_uuid: event_uuid},
              %{"delivery_pk" => key},
              %{
                "delivery_pk" => key,
                "endpoint_id" => endpoint_id,
                "event_uuid" => event_uuid
              }
            ] do
          args = Map.put(identity, "tenant", tenant)
          assert {:cancel, :delivery_missing} = f.worker.perform(%Oban.Job{args: args})

          assert_receive {:worker_outcome, [:ash_hooks, :delivery, :missing], %{}, metadata}

          expected =
            identity
            |> Map.new(fn {key, value} -> {to_string(key), value} end)
            |> Map.put("tenant", tenant)

          assert Map.new(metadata, fn {key, value} -> {to_string(key), value} end) == expected
          refute_received {:worker_outcome, _, _, _}
        end
      end

      test "absent partial and malformed delivery identities cancel without a missing event", f do
        for identity <- [
              %{},
              %{"endpoint_id" => Ash.UUID.generate()},
              %{"event_uuid" => Ash.UUID.generate()},
              %{"endpoint_id" => 123, "event_uuid" => "event"},
              %{"endpoint_id" => "not-a-uuid", "event_uuid" => "event"},
              %{"endpoint_id" => Ash.UUID.generate(), "event_uuid" => ""},
              %{"delivery_pk" => %{}},
              %{"delivery_pk" => %{"id" => "not-a-uuid"}},
              %{"delivery_pk" => "not-a-map"}
            ] do
          args = Map.put(identity, "tenant", "tenant-a")
          assert {:cancel, :invalid_delivery_identity} = f.worker.perform(%Oban.Job{args: args})
        end

        refute_received {:worker_outcome, _, _, _}
      end

      test "real storage read failures remain retryable rather than missing", f do
        id = Ash.UUID.generate()

        for resource <- [:outbox, :delivery] do
          original = Cases.table(f[resource])
          temporary = original <> "_unavailable"
          f.owner.query!("ALTER TABLE #{original} RENAME TO #{temporary}")

          try do
            job =
              if resource == :outbox,
                do: fanout_job(f, id),
                else: %Oban.Job{
                  args: %{"delivery_pk" => %{"id" => id}, "tenant" => "tenant-a"}
                }

            assert {:error, _reason} = f.worker.perform(job)

            if resource == :outbox do
              assert_receive {:worker_outcome, [:ash_hooks, :outbox, :claim], %{count: 1},
                              %{
                                event_uuid: ^id,
                                outcome: :error,
                                reason: "unclassified",
                                tenant: "tenant-a"
                              }}
            end

            refute_received {:worker_outcome, _, _, _}
          after
            f.owner.query!("ALTER TABLE #{temporary} RENAME TO #{original}")
          end
        end
      end

      test "a real claim write failure emits exactly one error claim and preserves the row", f do
        event = Cases.event()
        assert {:ok, :accepted} = Cases.publish(f, event)
        table = Cases.table(f.outbox)

        if f.sqlite? do
          f.owner.query!("""
          CREATE TRIGGER reject_worker_claim BEFORE UPDATE ON #{table}
          BEGIN
            SELECT RAISE(ABORT, 'forced claim rejection');
          END
          """)
        else
          f.owner.query!("REVOKE UPDATE ON #{table} FROM #{f.roles.runtime}", [], log: false)
        end

        try do
          assert {:error, _reason} = f.worker.perform(fanout_job(f, event.id))

          assert_receive {:worker_outcome, [:ash_hooks, :outbox, :claim], %{count: 1},
                          %{outcome: :error, reason: "unclassified", tenant: "tenant-a"}}

          refute_received {:worker_outcome, _, _, _}
        after
          if f.sqlite?,
            do: f.owner.query!("DROP TRIGGER reject_worker_claim"),
            else: f.owner.query!("GRANT UPDATE ON #{table} TO #{f.roles.runtime}", [], log: false)
        end

        assert %{state: :pending, attempts: 0} = Cases.publication(f, event.id)
      end

      if @namespace == AshHooks.OutboxFixtures.Postgres do
        test "unbound forced row security cancels hidden publications and deliveries visibly",
             f do
          Cases.endpoint(f)
          event = Cases.event()
          assert {:ok, :accepted} = Cases.publish(f, event)
          assert :done = Cases.fanout(f, event.id)
          assert [%{id: delivery_id} = row] = Cases.rows(f, :delivery)
          assert_receive {:worker_outcome, name, %{count: 1}, metadata}
          assert name == [:ash_hooks, :outbox, :claim]
          assert metadata.outcome == :claimed
          assert metadata.tenant == "tenant-a"

          assert_receive {:worker_outcome, [:ash_hooks, :outbox, :result], _,
                          %{outcome: :done, tenant: "tenant-a"}}
          Application.put_env(:ash_hooks, :outbox_skip_tenant_binding, true)

          try do
            assert {:cancel, :publication_missing} = f.worker.perform(fanout_job(f, event.id))

            assert_receive {:worker_outcome, [:ash_hooks, :outbox, :claim], %{count: 1},
                            %{event_uuid: id, outcome: :missing, reason: nil, tenant: "tenant-a"}}

            assert id == event.id
            key = AshHooks.PrimaryKey.encode(row)

            assert {:cancel, :delivery_missing} =
                     f.worker.perform(%Oban.Job{
                       args: %{"delivery_pk" => key, "tenant" => "tenant-a"}
                     })

            assert_receive {:worker_outcome, [:ash_hooks, :delivery, :missing], %{},
                            %{delivery_pk: ^key, tenant: "tenant-a"} = metadata}

            assert map_size(metadata) == 2
            refute_received {:worker_outcome, _, _, _}
          after
            Application.delete_env(:ash_hooks, :outbox_skip_tenant_binding)
          end

          assert %{state: :done} = Cases.publication(f, event.id)
          assert [%{id: ^delivery_id, status: :pending}] = Cases.rows(f, :delivery)
        end
      end

      defp fanout_job(f, id) do
        %Oban.Job{
          args: %{
            "kind" => "fanout",
            "outbox_resource" => Atom.to_string(f.outbox),
            "event_uuid" => id,
            "tenant" => "tenant-a"
          }
        }
      end
    end
  end
end
