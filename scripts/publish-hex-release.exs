unless is_nil(Mix.Project.get()) do
  Mix.raise("Release uploads must run outside a Mix project")
end

defmodule PublishHexRelease do
  def run do
    [version, package_path, docs_path, package_state, docs_state] = System.argv()

    unless match?({:ok, _}, Version.parse(version)) and
             package_state in ["upload", "served"] and docs_state in ["upload", "served"] do
      Mix.raise("Expected a release version and upload or served decisions")
    end

    package = File.read!(package_path)
    docs = File.read!(docs_path)
    Hex.start()
    Code.ensure_loaded!(Hex.API.Release)
    Code.ensure_loaded!(Hex.API.ReleaseDocs)
    key = System.fetch_env!("HEX_API_KEY")
    if String.trim(key) == "", do: Mix.raise("HEX_API_KEY is empty")
    auth = [key: key]

    package_result =
      upload(package_state, "package", package, fn ->
        Hex.API.Release.publish(nil, package, auth, fn _ -> :ok end, replace: false)
      end)

    # Hex's docs upload has no replace guard: it writes onto whatever release
    # holds this version. Docs follow only a package that is served, accepted
    # or held for approval, never a refused or failed package upload.
    if package_result == :error, do: System.halt(1)

    docs_result =
      upload(docs_state, "docs", docs, fn ->
        Hex.API.ReleaseDocs.publish(nil, "ash_hooks", version, docs, auth)
      end)

    case {package_result, docs_result} do
      {{:staged, package}, {:staged, %{"kind" => "release"} = docs}} ->
        unless is_binary(package["checksum"]) and package["checksum"] == docs["checksum"] do
          Mix.raise("Staged release changed before its docs were staged")
        end

      _ ->
        :ok
    end

    if Enum.any?([package_result, docs_result], &match?({:staged, _}, &1)) do
      IO.puts(:stderr, """
      Release held for approval; after the owner approves, dispatch again on the same commit.
      The next dispatch uploads only what is missing and reads both archives back.
      """)

      System.halt(1)
    end

    if :error in [package_result, docs_result], do: System.halt(1)
  end

  defp upload("served", kind, _archive, _request) do
    IO.puts("#{kind}: already served; upload skipped")
    :ok
  end

  defp upload("upload", kind, archive, request) do
    case request.() do
      {:ok, {status, _headers, %{"status" => "staged"} = staged}}
      when status in 200..299 ->
        digest = :crypto.hash(:sha256, archive) |> Base.encode16(case: :lower)
        IO.puts("#{kind}: held for approval")

        for field <- ["kind", "html_url", "expires_at"] do
          value = staged[field] || if(field == "kind", do: kind, else: "unspecified")
          value = if is_binary(value), do: Hex.Utils.printable_ascii(value), else: "unspecified"
          IO.puts("#{field}: #{value}")
        end

        IO.puts("SHA-256: #{digest}")
        {:staged, staged}

      {:ok, {status, _headers, _body}} when status in 200..299 ->
        IO.puts("#{kind}: accepted (HTTP #{status})")
        :ok

      {:ok, {status, _headers, _body}} when is_integer(status) ->
        IO.puts(:stderr, "#{kind}: upload refused (HTTP #{status})")
        :error

      _ ->
        IO.puts(:stderr, "#{kind}: upload failed without an HTTP response")
        :error
    end
  rescue
    _ ->
      IO.puts(:stderr, "#{kind}: upload failed without an HTTP response")
      :error
  catch
    _, _ ->
      IO.puts(:stderr, "#{kind}: upload failed without an HTTP response")
      :error
  end
end

PublishHexRelease.run()
