defmodule AshHooks.Test.TableCustodian do
  @moduledoc false

  defmacro __using__(opts) do
    quote do
      @behaviour AshHooks.Custody
      @repo unquote(Keyword.fetch!(opts, :repo))
      @postgres unquote(Keyword.get(opts, :postgres, false))
      @table "custody_conformance_keys"

      unquote(storage_definitions())
      unquote(signing_definition())
      unquote(verification_definition())
      unquote(disclosure_definitions())
      unquote(storage_helpers())
      unquote(material_result_helpers())
      unquote(lookup_helpers())
      unquote(material_helpers())
      unquote(connection_helpers())
    end
  end

  defp storage_definitions do
    quote do
      def setup_store! do
        @repo.query!(
          """
          CREATE TABLE #{@table} (
            ref TEXT PRIMARY KEY,
            tenant TEXT,
            kind TEXT,
            material TEXT,
            destroyed INTEGER NOT NULL CHECK (destroyed IN (0, 1))
          )
          """,
          [],
          log: false
        )
      end

      def drop_store!, do: @repo.query!("DROP TABLE #{@table}", [], log: false)

      @impl true
      def store(ref, material, tenant, kind) do
        transaction(fn ->
          if valid_material?(material, kind) do
            store_valid(ref, material, tenant, kind)
          else
            invalid_material_result(ref)
          end
        end)
      end

      @impl true
      def destroy(ref, tenant) do
        transaction(fn ->
          [bound_tenant, _kind, _material, _destroyed] = bind(ref, tenant, nil, nil, 1)

          if bound_tenant == tenant do
            query(
              "UPDATE #{@table} SET destroyed = 1, material = NULL, kind = NULL WHERE ref = ?",
              [ref]
            )

            :ok
          else
            {:error, :tenant_mismatch}
          end
        end)
      end

      # The upsert takes the global ref's write lock even when it exists.
      # The transaction retains it through comparison and the destroy update.
      defp bind(ref, tenant, kind, material, destroyed) do
        query(
          """
          INSERT INTO #{@table} (ref, tenant, kind, material, destroyed) VALUES (?, ?, ?, ?, ?)
          ON CONFLICT (ref) DO UPDATE SET ref = excluded.ref
          RETURNING tenant, kind, material, destroyed
          """,
          [ref, tenant, kind, material, destroyed]
        ).rows
        |> hd()
      end
    end
  end

  defp signing_definition do
    quote do
      @impl true
      def sign(ref, tenant, kind, input) do
        with {:ok, material} <- fetch(ref, tenant, kind) do
          case kind do
            {:sender_hmac, _} ->
              {:error, :not_signable}

            {:standard_webhooks, :v1a} ->
              {:ok, :crypto.sign(:eddsa, :none, input, [material, :ed25519])}

            {_, digest} ->
              digest = crypto_digest(digest)
              {:ok, :crypto.mac(:hmac, digest, material, input)}
          end
        end
      end
    end
  end

  defp verification_definition do
    quote do
      @impl true
      def verify(ref, tenant, kind, input, mac) do
        with {:ok, material} <- fetch(ref, tenant, kind) do
          valid? =
            case kind do
              {:standard_webhooks, :v1a} ->
                {public, _} = :crypto.generate_key(:eddsa, :ed25519, material)

                byte_size(mac) == 64 and
                  :crypto.verify(:eddsa, :none, input, mac, [public, :ed25519])

              {_, digest} ->
                digest = crypto_digest(digest)
                expected = :crypto.mac(:hmac, digest, material, input)
                byte_size(mac) == byte_size(expected) and :crypto.hash_equals(expected, mac)
            end

          if valid?, do: :ok, else: {:error, :invalid_signature}
        end
      end
    end
  end

  defp disclosure_definitions do
    quote do
      @impl true
      def public_key(ref, tenant, kind) do
        with {:ok, material} <- fetch(ref, tenant, kind) do
          if kind == {:standard_webhooks, :v1a} do
            {public, _} = :crypto.generate_key(:eddsa, :ed25519, material)
            {:ok, public}
          else
            {:error, :no_public_half}
          end
        end
      end

      @impl true
      def fingerprint(ref, tenant, kind) do
        with {:ok, material} <- fetch(ref, tenant, kind) do
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
    end
  end

  defp storage_helpers do
    quote do
      defp store_valid(ref, material, tenant, kind) do
        [bound_tenant, bound_kind, bound_material, destroyed] =
          bind(ref, tenant, encode_kind(kind), Base.encode64(material), 0)

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
    end
  end

  defp material_result_helpers do
    quote do
      defp invalid_material_result(ref) do
        case query("SELECT destroyed FROM #{@table} WHERE ref = ?", [ref]).rows do
          [[1]] -> {:error, :ref_destroyed}
          _ -> {:error, :invalid_material}
        end
      end

      defp fingerprint_material(material, :v1), do: material

      defp fingerprint_material(material, :v1a) do
        {public, _} = :crypto.generate_key(:eddsa, :ed25519, material)
        public
      end
    end
  end

  defp lookup_helpers do
    quote do
      defp fetch(ref, tenant, kind) do
        case query(
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
    end
  end

  defp material_helpers do
    quote do
      defp valid_material?(material, {:standard_webhooks, :v1}),
        do: byte_size(material) in 24..64

      defp valid_material?(material, {:standard_webhooks, :v1a}), do: byte_size(material) == 32

      defp valid_material?(material, {:sender_hmac, digest})
           when digest in [:sha1, :sha256, :sha384, :sha512],
           do: byte_size(material) in 1..16_384

      defp valid_material?(material, {:legacy_hmac, :sha256}), do: byte_size(material) > 0
      defp encode_kind({family, digest}), do: "#{family}:#{digest}"

      defp crypto_digest(:v1), do: :sha256
      defp crypto_digest(:sha1), do: :sha
      defp crypto_digest(digest), do: digest
    end
  end

  defp connection_helpers do
    quote do
      defp transaction(fun) do
        {:ok, result} = @repo.transaction(fun, log: false)
        result
      end

      defp query(sql, params) do
        sql =
          if @postgres do
            sql
            |> String.split("?")
            |> Enum.with_index()
            |> Enum.map_join(fn
              {part, 0} -> part
              {part, index} -> "$#{index}" <> part
            end)
          else
            sql
          end

        @repo.query!(sql, params, log: false)
      end
    end
  end
end

defmodule AshHooks.Test.Custodian do
  @moduledoc false
  use AshHooks.Test.TableCustodian, repo: AshHooks.Test.Repo
end

defmodule AshHooks.TestPostgres.Custodian do
  @moduledoc false
  use AshHooks.Test.TableCustodian, repo: AshHooks.TestPostgres.Repo, postgres: true
end
