defmodule AshHooks.OutboxProcess do
  @moduledoc false

  def checkpoint(stage) do
    case Application.get_env(:ash_hooks, :outbox_checkpoint) do
      {^stage, path} ->
        File.write!(path, System.pid())
        wait_for_release(path)

      _other ->
        :ok
    end
  end

  defp wait_for_release(path) do
    if File.exists?(path <> ".release") do
      :ok
    else
      Process.sleep(10)
      wait_for_release(path)
    end
  end

  def variant(event) do
    count = Process.get(:outbox_builder_calls, 0) + 1
    Process.put(:outbox_builder_calls, count)

    if observer = Application.get_env(:ash_hooks, :outbox_observer),
      do: send(observer, {:outbox_builder, self()})

    if count == 2, do: checkpoint(:mid_fanout)
    {:ok, "v2:" <> event.payload}
  end

  def admit(runtime, row, event) do
    checkpoint(:before_admission)
    namespace = runtime |> Module.split() |> Enum.drop(-1) |> Module.concat()
    marker = Application.get_env(:ash_hooks, :outbox_admission_marker)

    cond do
      marker && event.metadata["admission"] != "fail" ->
        {:error, :metadata_missing}

      (event.metadata["admission"] == "fail" and marker) && not File.exists?(marker) ->
        File.write!(marker, "refused")
        {:error, :closed}

      true ->
        worker = Module.concat(namespace, :RouteWorker)
        oban = Module.concat(namespace, :Oban)

        args = %{
          "delivery_pk" => AshHooks.PrimaryKey.encode(row),
          "delivery_resource" => Atom.to_string(row.__struct__),
          "endpoint_resource" => Atom.to_string(Module.concat(namespace, :Endpoint)),
          "endpoint_id" => row.endpoint_id,
          "event_uuid" => row.event_uuid,
          "dispatch_source" => row.dispatch_source,
          "dispatch_route" => row.dispatch_route,
          "tenant" => AshHooks.Tenancy.from_row(row)
        }

        result =
          AshHooks.Phase.run(row.__struct__, args["tenant"], fn ->
            Oban.insert(
              oban,
              worker.new(args,
                unique: [
                  fields: [:args],
                  period: :infinity,
                  states: [:available, :scheduled, :executing, :retryable]
                ]
              )
            )
          end)

        case result do
          {:ok, %{id: id}} when is_integer(id) ->
            checkpoint(:after_admission)
            :ok

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def secret(_reference), do: {:ok, :crypto.strong_rand_bytes(32)}

  def deliver(namespace, args) do
    AshHooks.Delivery.run(args,
      deliveries: Module.concat(namespace, :Delivery),
      endpoints: Module.concat(namespace, :Endpoint),
      secret_resolver: {__MODULE__, :secret},
      ssrf_check: &AshHooks.Ssrf.registration_safe?/1,
      http_opts: [validate_destination: false, timeout: 500],
      attempt_timeout: 2_000,
      finalization_allowance: 1_000
    )
  end

  def boot(repo, config, oban_options) do
    for app <- [:ash_hooks, :ash_postgres, :ash_sqlite] do
      {:ok, _} = Application.ensure_all_started(app)
    end

    Application.put_env(:ash_hooks, repo, config)
    {:ok, pid} = repo.start_link()
    Process.unlink(pid)

    if oban_options do
      {:ok, _} = Application.ensure_all_started(:oban)
      {:ok, oban} = Oban.start_link(oban_options)
      Process.unlink(oban)
    end

    :ok
  end

  defp bind(AshHooks.OutboxFixtures.Postgres.Repo = repo),
    do:
      repo.query!("SELECT set_config('outbox_acceptance.tenant', $1, true)", ["tenant-a"],
        log: false
      )

  defp bind(_repo), do: :ok

  defp deploy_version_one(emitter) do
    source = File.read!(Path.expand("test/ash_hooks/outbox_resources.exs"))
    {:__block__, _, modules} = Code.string_to_quoted!(source)

    definition =
      Enum.find(modules, fn
        {:defmodule, _, [alias_ast, _]} -> Module.concat(elem(alias_ast, 2)) == emitter
        _ -> false
      end)

    definition =
      Macro.prewalk(definition, fn
        {:version, meta, [2]} -> {:version, meta, [1]}
        node -> node
      end)

    Code.compile_quoted(definition)
  end

  def execute(namespace, stage, event, path, marker) do
    Application.put_env(:ash_hooks, :outbox_checkpoint, {stage, path})
    if marker, do: Application.put_env(:ash_hooks, :outbox_admission_marker, marker)
    outbox = Module.concat(namespace, :Outbox)
    emitter = Module.concat(namespace, :Emitter)
    repo = AshHooks.Phase.repo(outbox)

    spawn(fn ->
      case stage do
        :before_commit ->
          repo.transaction(fn ->
            bind(repo)

            {:ok, :accepted} =
              AshHooks.publish(outbox, {emitter, :changed}, event, tenant: "tenant-a")

            checkpoint(stage)
          end)

        :after_commit ->
          {:ok, :ok} =
            repo.transaction(fn ->
              bind(repo)

              {:ok, :accepted} =
                AshHooks.publish(outbox, {emitter, :changed}, event, tenant: "tenant-a")

              :ok
            end)

          checkpoint(stage)

        version when version in [:version_one, :version_one_partial] ->
          deploy_version_one(emitter)

          {:ok, :accepted} =
            AshHooks.publish(outbox, {emitter, :changed}, event, tenant: "tenant-a")

          if version == :version_one_partial do
            {:pending, :unknown_pinned_version} =
              AshHooks.fanout(outbox, event.id, tenant: "tenant-a")
          end

          checkpoint(stage)

        :admission_failure ->
          {:pending, _} = AshHooks.fanout(outbox, event.id, tenant: "tenant-a")
          checkpoint(stage)

        _fanout ->
          AshHooks.fanout(outbox, event.id, tenant: "tenant-a")
      end
    end)

    :ok
  end
end

if Code.ensure_loaded?(Oban) do
  defmodule AshHooks.OutboxFixtures.SQLite.RouteWorker do
    use Oban.Worker, queue: :outbox_acceptance

    def perform(%Oban.Job{args: args}),
      do: AshHooks.OutboxProcess.deliver(AshHooks.OutboxFixtures.SQLite, args)
  end

  defmodule AshHooks.OutboxFixtures.Postgres.RouteWorker do
    use Oban.Worker, queue: :outbox_acceptance

    def perform(%Oban.Job{args: args}),
      do: AshHooks.OutboxProcess.deliver(AshHooks.OutboxFixtures.Postgres, args)
  end

  defmodule AshHooks.OutboxFixtures.ObanMigration do
    use Ecto.Migration
    def change, do: Oban.Migrations.up(prefix: "outbox_acceptance_oban")
  end
end
