defmodule AshHooks.OutboxFixtures.HostNotifier do
  use Ash.Notifier

  def notify(notification) do
    if observer = Application.get_env(:ash_hooks, :outbox_host_observer),
      do: send(observer, {:host_notification, notification})

    :ok
  end
end

defmodule AshHooks.OutboxFixtures.HostNotifications do
  use Ash.Resource.Change

  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, row ->
      notification = %Ash.Notifier.Notification{
        resource: row.__struct__,
        action: changeset.action,
        for: [AshHooks.OutboxFixtures.HostNotifier],
        data: row,
        metadata: %{host: true}
      }

      {:ok, row, [notification]}
    end)
  end
end

defmodule AshHooks.OutboxFixtures.SubscriptionPreparation do
  use Ash.Resource.Preparation

  def prepare(query, _opts, _context) do
    case Application.get_env(:ash_hooks, :outbox_read_failure) do
      :raise -> raise "subscription preparation failed"
      :throw -> throw(:subscription_preparation_failed)
      _other -> query
    end
  end
end

defmodule AshHooks.OutboxFixtures.Postgres.Repo do
  use AshPostgres.Repo, otp_app: :ash_hooks, warn_on_missing_ash_functions?: false
  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}

  def on_transaction_begin(reason) do
    if tenant = reason[:tenant] do
      query!(
        "SELECT set_config('outbox_acceptance.tenant', $1, true)",
        [to_string(tenant)],
        log: false
      )
    end

    :ok
  end
end

defmodule AshHooks.OutboxFixtures.Postgres.EngineRepo do
  use AshPostgres.Repo, otp_app: :ash_hooks, warn_on_missing_ash_functions?: false
  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
end

defmodule AshHooks.OutboxFixtures.SQLiteRepo do
  use AshSqlite.Repo, otp_app: :ash_hooks
  def write_transactions?, do: true
  def min_sqlite_version, do: %Version{major: 3, minor: 54, patch: 1}
end

defmodule AshHooks.OutboxFixtures.SQLite.Runtime do
  def build(record, _context) do
    AshHooks.Event.new(id: "msg_record_" <> record.id, type: :changed, payload: record.value)
  end

  def variant(event), do: AshHooks.OutboxProcess.variant(event)

  def trigger(row, tenant) do
    case Application.get_env(:ash_hooks, __MODULE__) do
      nil ->
        :ok

      pid when is_pid(pid) ->
        send(pid, {:triggered, row.event_uuid, tenant})
        :ok

      :oban ->
        worker =
          row.__struct__
          |> Module.split()
          |> Enum.drop(-1)
          |> Module.concat()
          |> Module.concat(:Worker)

        worker.enqueue_fanout(row, tenant)

      :raise ->
        raise "trigger failed"

      :exit ->
        exit(:trigger_failed)

      :throw ->
        throw(:trigger_failed)

      :error ->
        {:error, :trigger_failed}
    end
  end

  def enqueue(row, event), do: AshHooks.OutboxProcess.admit(__MODULE__, row, event)
end

defmodule AshHooks.OutboxFixtures.SQLite.Endpoint do
  use Ash.Resource,
    domain: AshHooks.OutboxFixtures.SQLite.Domain,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshHooks.Endpoint]

  sqlite do
    table "outbox_sqlite_endpoints"
    repo(AshHooks.OutboxFixtures.SQLiteRepo)
  end

  attributes do
    attribute :org_id, :string, allow_nil?: false
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  actions do
    default_accept :*
    defaults [:read, :create, :update]
  end

  endpoint do
    version_pinning :on
  end
end

defmodule AshHooks.OutboxFixtures.SQLite.Subscription do
  use Ash.Resource,
    domain: AshHooks.OutboxFixtures.SQLite.Domain,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshHooks.Subscription]

  sqlite do
    table "outbox_sqlite_subscriptions"
    repo(AshHooks.OutboxFixtures.SQLiteRepo)
  end

  attributes do
    attribute :org_id, :string, allow_nil?: false
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  actions do
    default_accept :*
    defaults [:read, :create, :update]
  end

  preparations do
    prepare AshHooks.OutboxFixtures.SubscriptionPreparation
  end

  subscription do
    endpoint_resource AshHooks.OutboxFixtures.SQLite.Endpoint
    filter_attributes [:region, :flag, :disabled, :nullable, :count, :nested, :__invalid__]
    pausable :on
  end
end

defmodule AshHooks.OutboxFixtures.SQLite.Delivery do
  use Ash.Resource,
    domain: AshHooks.OutboxFixtures.SQLite.Domain,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshHooks.OutboundDelivery]

  sqlite do
    table "outbox_sqlite_deliveries"
    repo(AshHooks.OutboxFixtures.SQLiteRepo)
  end

  attributes do
    attribute :org_id, :string, allow_nil?: false
    timestamps()
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  actions do
    defaults [:read]
  end
end

if Code.ensure_loaded?(Oban) do
  defmodule AshHooks.OutboxFixtures.SQLite.Worker do
    use AshHooks.Worker,
      deliveries: AshHooks.OutboxFixtures.SQLite.Delivery,
      endpoints: AshHooks.OutboxFixtures.SQLite.Endpoint,
      outbox: AshHooks.OutboxFixtures.SQLite.Outbox,
      oban: AshHooks.OutboxFixtures.SQLite.Oban,
      queue: :outbox_acceptance
  end
end

defmodule AshHooks.OutboxFixtures.SQLite.Outbox do
  use Ash.Resource,
    domain: AshHooks.OutboxFixtures.SQLite.Domain,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshHooks.OutboundOutbox]

  sqlite do
    table "outbox_sqlite_publications"
    repo(AshHooks.OutboxFixtures.SQLiteRepo)
  end

  attributes do
    attribute :org_id, :string, allow_nil?: false
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  actions do
    defaults [:read]
  end

  outbox do
    declarations [
      {AshHooks.OutboxFixtures.SQLite.Emitter, :removed},
      {AshHooks.OutboxFixtures.SQLite.Emitter, :changed}
    ]

    delivery_routes default: nil, queued: {AshHooks.OutboxFixtures.SQLite.Runtime, :enqueue}
    # Worker routes are exercised where Oban is installed.
    trigger {AshHooks.OutboxFixtures.SQLite.Runtime, :trigger}
    deduplication_horizon_seconds 3600
    fanout_timeout 1_000
    fanout_lease_seconds 2
    fanout_max_attempts 3
    fanout_base_backoff_seconds 1
    fanout_max_backoff_seconds 2
  end
end

defmodule AshHooks.OutboxFixtures.SQLite.Emitter do
  use Ash.Resource,
    domain: AshHooks.OutboxFixtures.SQLite.Domain,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshHooks]

  sqlite do
    table "outbox_sqlite_emitters"
    repo(AshHooks.OutboxFixtures.SQLiteRepo)
  end

  attributes do
    attribute :org_id, :string, allow_nil?: false
    uuid_primary_key :id
    attribute :value, :string, default: "body", public?: true
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  actions do
    default_accept :*
    defaults [:read]

    create :create do
      primary? true

      change {AshHooks.Changes.Publish,
              outbox: AshHooks.OutboxFixtures.SQLite.Outbox,
              declaration: {AshHooks.OutboxFixtures.SQLite.Emitter, :changed},
              build: {AshHooks.OutboxFixtures.SQLite.Runtime, :build}}
    end

    update :update do
      primary? true
      require_atomic? true

      change {AshHooks.Changes.Publish,
              outbox: AshHooks.OutboxFixtures.SQLite.Outbox,
              declaration: {AshHooks.OutboxFixtures.SQLite.Emitter, :changed},
              build: {AshHooks.OutboxFixtures.SQLite.Runtime, :build}}
    end

    update :revise do
      require_atomic? true

      change {AshHooks.Changes.Publish,
              outbox: AshHooks.OutboxFixtures.SQLite.Outbox,
              declaration: {AshHooks.OutboxFixtures.SQLite.Emitter, :changed},
              build: {AshHooks.OutboxProcess, :build_revision}}
    end

    create :outer do
      argument :inner_kind, :atom, constraints: [one_of: [:normal, :bulk, :atomic]]
      argument :inner_id, :uuid
      argument :undo, :boolean, default: false
      change after_action(&AshHooks.OutboxProcess.nested/3)
    end
  end

  webhooks do
    outbound :changed do
      subscriptions AshHooks.OutboxFixtures.SQLite.Subscription
      deliveries AshHooks.OutboxFixtures.SQLite.Delivery
      version 2

      payload_versions %{
        1 => {AshHooks.OutboxFixtures.SQLite.Runtime, :variant},
        2 => {AshHooks.OutboxFixtures.SQLite.Runtime, :variant}
      }
    end
  end
end

defmodule AshHooks.OutboxFixtures.SQLite.Domain do
  use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

  resources do
    resource AshHooks.OutboxFixtures.SQLite.Endpoint
    resource AshHooks.OutboxFixtures.SQLite.Subscription
    resource AshHooks.OutboxFixtures.SQLite.Delivery
    resource AshHooks.OutboxFixtures.SQLite.Outbox
    resource AshHooks.OutboxFixtures.SQLite.Emitter
  end
end

defmodule AshHooks.OutboxFixtures.Postgres.Runtime do
  def build(record, _context) do
    AshHooks.Event.new(id: "msg_record_" <> record.id, type: :changed, payload: record.value)
  end

  def variant(event), do: AshHooks.OutboxProcess.variant(event)

  def trigger(row, tenant) do
    case Application.get_env(:ash_hooks, __MODULE__) do
      nil ->
        :ok

      pid when is_pid(pid) ->
        send(pid, {:triggered, row.event_uuid, tenant})
        :ok

      :oban ->
        worker =
          row.__struct__
          |> Module.split()
          |> Enum.drop(-1)
          |> Module.concat()
          |> Module.concat(:Worker)

        worker.enqueue_fanout(row, tenant)

      :raise ->
        raise "trigger failed"

      :exit ->
        exit(:trigger_failed)

      :throw ->
        throw(:trigger_failed)

      :error ->
        {:error, :trigger_failed}
    end
  end

  def enqueue(row, event), do: AshHooks.OutboxProcess.admit(__MODULE__, row, event)
end

defmodule AshHooks.OutboxFixtures.Postgres.Endpoint do
  use Ash.Resource,
    domain: AshHooks.OutboxFixtures.Postgres.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshHooks.Endpoint]

  postgres do
    table "outbox_postgres_endpoints"
    repo(AshHooks.OutboxFixtures.Postgres.Repo)
  end

  attributes do
    attribute :org_id, :string, allow_nil?: false
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  actions do
    default_accept :*
    defaults [:read, :create, :update]
  end

  endpoint do
    version_pinning :on
  end
end

defmodule AshHooks.OutboxFixtures.Postgres.Subscription do
  use Ash.Resource,
    domain: AshHooks.OutboxFixtures.Postgres.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshHooks.Subscription]

  postgres do
    table "outbox_postgres_subscriptions"
    repo(AshHooks.OutboxFixtures.Postgres.Repo)
  end

  attributes do
    attribute :org_id, :string, allow_nil?: false
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  actions do
    default_accept :*
    defaults [:read, :create, :update]
  end

  preparations do
    prepare AshHooks.OutboxFixtures.SubscriptionPreparation
  end

  subscription do
    endpoint_resource AshHooks.OutboxFixtures.Postgres.Endpoint
    filter_attributes [:region, :flag, :disabled, :nullable, :count, :nested, :__invalid__]
    pausable :on
  end
end

defmodule AshHooks.OutboxFixtures.Postgres.Delivery do
  use Ash.Resource,
    domain: AshHooks.OutboxFixtures.Postgres.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshHooks.OutboundDelivery]

  postgres do
    table "outbox_postgres_deliveries"
    repo(AshHooks.OutboxFixtures.Postgres.Repo)
  end

  attributes do
    attribute :org_id, :string, allow_nil?: false
    uuid_v7_primary_key :id
    timestamps()
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  actions do
    defaults [:read]
  end
end

if Code.ensure_loaded?(Oban) do
  defmodule AshHooks.OutboxFixtures.Postgres.Worker do
    use AshHooks.Worker,
      deliveries: AshHooks.OutboxFixtures.Postgres.Delivery,
      endpoints: AshHooks.OutboxFixtures.Postgres.Endpoint,
      outbox: AshHooks.OutboxFixtures.Postgres.Outbox,
      oban: AshHooks.OutboxFixtures.Postgres.Oban,
      queue: :outbox_acceptance
  end
end

defmodule AshHooks.OutboxFixtures.Postgres.Outbox do
  use Ash.Resource,
    domain: AshHooks.OutboxFixtures.Postgres.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshHooks.OutboundOutbox]

  postgres do
    table "outbox_postgres_publications"
    repo(AshHooks.OutboxFixtures.Postgres.Repo)
  end

  attributes do
    attribute :org_id, :string, allow_nil?: false
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  actions do
    defaults [:read]
  end

  outbox do
    declarations [
      {AshHooks.OutboxFixtures.Postgres.Emitter, :removed},
      {AshHooks.OutboxFixtures.Postgres.Emitter, :changed}
    ]

    delivery_routes default: nil, queued: {AshHooks.OutboxFixtures.Postgres.Runtime, :enqueue}
    # Worker routes are exercised where Oban is installed.
    trigger {AshHooks.OutboxFixtures.Postgres.Runtime, :trigger}
    deduplication_horizon_seconds 3600
    fanout_timeout 1_000
    fanout_lease_seconds 2
    fanout_max_attempts 3
    fanout_base_backoff_seconds 1
    fanout_max_backoff_seconds 2
  end
end

defmodule AshHooks.OutboxFixtures.Postgres.Emitter do
  use Ash.Resource,
    domain: AshHooks.OutboxFixtures.Postgres.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshHooks]

  postgres do
    table "outbox_postgres_emitters"
    repo(AshHooks.OutboxFixtures.Postgres.Repo)
  end

  attributes do
    attribute :org_id, :string, allow_nil?: false
    uuid_primary_key :id
    attribute :value, :string, default: "body", public?: true
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  actions do
    default_accept :*
    defaults [:read]

    create :create do
      primary? true

      change {AshHooks.Changes.Publish,
              outbox: AshHooks.OutboxFixtures.Postgres.Outbox,
              declaration: {AshHooks.OutboxFixtures.Postgres.Emitter, :changed},
              build: {AshHooks.OutboxFixtures.Postgres.Runtime, :build}}
    end

    update :update do
      primary? true
      require_atomic? true

      change {AshHooks.Changes.Publish,
              outbox: AshHooks.OutboxFixtures.Postgres.Outbox,
              declaration: {AshHooks.OutboxFixtures.Postgres.Emitter, :changed},
              build: {AshHooks.OutboxFixtures.Postgres.Runtime, :build}}
    end

    update :revise do
      require_atomic? true

      change {AshHooks.Changes.Publish,
              outbox: AshHooks.OutboxFixtures.Postgres.Outbox,
              declaration: {AshHooks.OutboxFixtures.Postgres.Emitter, :changed},
              build: {AshHooks.OutboxProcess, :build_revision}}
    end

    create :outer do
      argument :inner_kind, :atom, constraints: [one_of: [:normal, :bulk, :atomic]]
      argument :inner_id, :uuid
      argument :undo, :boolean, default: false
      change after_action(&AshHooks.OutboxProcess.nested/3)
    end
  end

  webhooks do
    outbound :changed do
      subscriptions AshHooks.OutboxFixtures.Postgres.Subscription
      deliveries AshHooks.OutboxFixtures.Postgres.Delivery
      version 2

      payload_versions %{
        1 => {AshHooks.OutboxFixtures.Postgres.Runtime, :variant},
        2 => {AshHooks.OutboxFixtures.Postgres.Runtime, :variant}
      }
    end
  end
end

defmodule AshHooks.OutboxFixtures.Postgres.Domain do
  use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

  resources do
    resource AshHooks.OutboxFixtures.Postgres.Endpoint
    resource AshHooks.OutboxFixtures.Postgres.Subscription
    resource AshHooks.OutboxFixtures.Postgres.Delivery
    resource AshHooks.OutboxFixtures.Postgres.Outbox
    resource AshHooks.OutboxFixtures.Postgres.Emitter
  end
end
