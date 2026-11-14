defmodule AshHooks.Test.TableCustodian do
  @moduledoc false
  # A real `AshHooks.Custody` implementation over one database table, used to
  # run the conformance template. Each custodian module below names its repo
  # and SQL dialect and delegates here. Tombstones and the global tenant
  # binding live in the table; every check-and-write runs in one transaction.

  @table "custody_conformance_keys"

  def setup_store!(store) do
    query!(
      store,
      """
      CREATE TABLE #{@table} (
        ref TEXT PRIMARY KEY,
        tenant TEXT,
        kind TEXT,
        material TEXT,
        destroyed INTEGER NOT NULL CHECK (destroyed IN (0, 1))
      )
      """,
      []
    )
  end

  def drop_store!(store), do: query!(store, "DROP TABLE #{@table}", [])

  def store(store, ref, material, tenant, kind) do
    transaction(store, fn ->
      if valid_material?(material, kind) do
        store_valid(store, ref, material, tenant, kind)
      else
        invalid_material_result(store, ref)
      end
    end)
  end

  def destroy(store, ref, tenant) do
    transaction(store, fn ->
      [bound_tenant, _kind, _material, _destroyed] = bind(store, ref, tenant, nil, nil, 1)

      if bound_tenant == tenant do
        query!(
          store,
          "UPDATE #{@table} SET destroyed = 1, material = NULL, kind = NULL WHERE ref = ?",
          [ref]
        )

        :ok
      else
        {:error, :tenant_mismatch}
      end
    end)
  end

  def sign(store, ref, tenant, kind, input) do
    with {:ok, material} <- fetch(store, ref, tenant, kind) do
      case kind do
        {:sender_hmac, _} ->
          {:error, :not_signable}

        {:standard_webhooks, :v1a} ->
          {:ok, :crypto.sign(:eddsa, :none, input, [material, :ed25519])}

        {_, digest} ->
          {:ok, :crypto.mac(:hmac, crypto_digest(digest), material, input)}
      end
    end
  end

  def verify(store, ref, tenant, kind, input, mac) do
    with {:ok, material} <- fetch(store, ref, tenant, kind) do
      valid? =
        case kind do
          {:standard_webhooks, :v1a} ->
            {public, _} = :crypto.generate_key(:eddsa, :ed25519, material)

            byte_size(mac) == 64 and
              :crypto.verify(:eddsa, :none, input, mac, [public, :ed25519])

          {_, digest} ->
            expected = :crypto.mac(:hmac, crypto_digest(digest), material, input)
            byte_size(mac) == byte_size(expected) and :crypto.hash_equals(expected, mac)
        end

      if valid?, do: :ok, else: {:error, :invalid_signature}
    end
  end

  def public_key(store, ref, tenant, kind) do
    with {:ok, material} <- fetch(store, ref, tenant, kind) do
      if kind == {:standard_webhooks, :v1a} do
        {public, _} = :crypto.generate_key(:eddsa, :ed25519, material)
        {:ok, public}
      else
        {:error, :no_public_half}
      end
    end
  end

  def fingerprint(store, ref, tenant, kind) do
    with {:ok, material} <- fetch(store, ref, tenant, kind) do
      case kind do
        {:standard_webhooks, version} ->
          bytes = fingerprint_material(material, version)

          digest =
            :crypto.hash(
              :sha256,
              "ash_hooks key fingerprint v1\0standard_webhooks.#{version}\0" <> bytes
            )

          {:ok, binary_part(digest, 0, 16)}

        _ ->
          {:error, :no_fingerprint}
      end
    end
  end

  # The upsert takes the global ref's write lock even when it exists.
  # The transaction retains it through comparison and the destroy update.
  defp bind(store, ref, tenant, kind, material, destroyed) do
    query!(
      store,
      """
      INSERT INTO #{@table} (ref, tenant, kind, material, destroyed) VALUES (?, ?, ?, ?, ?)
      ON CONFLICT (ref) DO UPDATE SET ref = excluded.ref
      RETURNING tenant, kind, material, destroyed
      """,
      [ref, tenant, kind, material, destroyed]
    ).rows
    |> hd()
  end

  defp store_valid(store, ref, material, tenant, kind) do
    [bound_tenant, bound_kind, bound_material, destroyed] =
      bind(store, ref, tenant, encode_kind(kind), Base.encode64(material), 0)

    cond do
      destroyed == 1 ->
        {:error, :ref_destroyed}

      {bound_tenant, bound_kind, bound_material} ==
          {tenant, encode_kind(kind), Base.encode64(material)} ->
        :ok

      true ->
        {:error, :ref_exists}
    end
  end

  defp invalid_material_result(store, ref) do
    case query!(store, "SELECT destroyed FROM #{@table} WHERE ref = ?", [ref]).rows do
      [[1]] -> {:error, :ref_destroyed}
      _ -> {:error, :invalid_material}
    end
  end

  defp fetch(store, ref, tenant, kind) do
    case query!(
           store,
           "SELECT tenant, kind, material FROM #{@table} WHERE ref = ? AND destroyed = 0",
           [ref]
         ).rows do
      [[^tenant, stored_kind, material]] ->
        if stored_kind == encode_kind(kind),
          do: {:ok, Base.decode64!(material)},
          else: {:error, :kind_mismatch}

      _ ->
        {:error, :unknown_ref}
    end
  end

  defp fingerprint_material(material, :v1), do: material

  defp fingerprint_material(material, :v1a) do
    {public, _} = :crypto.generate_key(:eddsa, :ed25519, material)
    public
  end

  defp valid_material?(material, {:standard_webhooks, :v1}), do: byte_size(material) in 24..64
  defp valid_material?(material, {:standard_webhooks, :v1a}), do: byte_size(material) == 32

  defp valid_material?(material, {:sender_hmac, digest})
       when digest in [:sha1, :sha256, :sha384, :sha512],
       do: byte_size(material) in 1..16_384

  defp valid_material?(material, {:legacy_hmac, :sha256}), do: byte_size(material) > 0

  defp encode_kind({family, digest}), do: "#{family}:#{digest}"

  defp crypto_digest(:v1), do: :sha256
  defp crypto_digest(:sha1), do: :sha
  defp crypto_digest(digest), do: digest

  defp transaction({repo, _dialect}, fun) do
    {:ok, result} = repo.transaction(fun, log: false)
    result
  end

  defp query!({repo, dialect}, sql, params),
    do: repo.query!(placeholders(sql, dialect), params, log: false)

  # SQLite takes `?`; PostgreSQL takes numbered `$n` parameters.
  defp placeholders(sql, :sqlite), do: sql

  defp placeholders(sql, :postgres) do
    sql
    |> String.split("?")
    |> Enum.with_index()
    |> Enum.map_join(fn
      {part, 0} -> part
      {part, index} -> "$#{index}" <> part
    end)
  end
end

defmodule AshHooks.Test.Custodian do
  @moduledoc false
  @behaviour AshHooks.Custody

  alias AshHooks.Test.TableCustodian

  @store {AshHooks.Test.Repo, :sqlite}

  def setup_store!, do: TableCustodian.setup_store!(@store)
  def drop_store!, do: TableCustodian.drop_store!(@store)

  @impl true
  def store(ref, material, tenant, kind),
    do: TableCustodian.store(@store, ref, material, tenant, kind)

  @impl true
  def sign(ref, tenant, kind, input), do: TableCustodian.sign(@store, ref, tenant, kind, input)

  @impl true
  def verify(ref, tenant, kind, input, mac),
    do: TableCustodian.verify(@store, ref, tenant, kind, input, mac)

  @impl true
  def public_key(ref, tenant, kind), do: TableCustodian.public_key(@store, ref, tenant, kind)

  @impl true
  def fingerprint(ref, tenant, kind), do: TableCustodian.fingerprint(@store, ref, tenant, kind)

  @impl true
  def destroy(ref, tenant), do: TableCustodian.destroy(@store, ref, tenant)
end

defmodule AshHooks.TestPostgres.Custodian do
  @moduledoc false
  @behaviour AshHooks.Custody

  alias AshHooks.Test.TableCustodian

  @store {AshHooks.TestPostgres.Repo, :postgres}

  def setup_store!, do: TableCustodian.setup_store!(@store)
  def drop_store!, do: TableCustodian.drop_store!(@store)

  @impl true
  def store(ref, material, tenant, kind),
    do: TableCustodian.store(@store, ref, material, tenant, kind)

  @impl true
  def sign(ref, tenant, kind, input), do: TableCustodian.sign(@store, ref, tenant, kind, input)

  @impl true
  def verify(ref, tenant, kind, input, mac),
    do: TableCustodian.verify(@store, ref, tenant, kind, input, mac)

  @impl true
  def public_key(ref, tenant, kind), do: TableCustodian.public_key(@store, ref, tenant, kind)

  @impl true
  def fingerprint(ref, tenant, kind), do: TableCustodian.fingerprint(@store, ref, tenant, kind)

  @impl true
  def destroy(ref, tenant), do: TableCustodian.destroy(@store, ref, tenant)
end
