unless is_nil(Mix.Project.get()) do
  Mix.raise("Release uploads must run outside a Mix project")
end

defmodule PublishHexRelease do
  def run do
    [version, package_path, docs_path, package_plan, docs_plan] = System.argv()

    unless match?({:ok, _}, Version.parse(version)) and
             package_plan in ["upload", "skip"] and docs_plan in ["upload", "skip"] do
      Mix.raise("Expected a release version and upload or skip decisions")
    end

    package = File.read!(package_path)
    docs = File.read!(docs_path)
    checksum = digest(package)
    Hex.start()
    Code.ensure_loaded!(Hex.API.Release)
    Code.ensure_loaded!(Hex.API.ReleaseDocs)
    key = System.fetch_env!("HEX_API_KEY")
    if String.trim(key) == "", do: Mix.raise("HEX_API_KEY is empty")
    auth = [key: key]

    package_result =
      case {package_plan, served_release(version, checksum)} do
        {_, {:served, _}} ->
          skip("package")

        {"upload", :missing} ->
          publish_package(version, package, checksum, auth)

        {"skip", :missing} ->
          Mix.raise("Hex no longer serves the package that the build planned to keep")
      end

    if package_result == :error, do: System.halt(1)

    docs_result = publish_docs(docs_plan, version, docs, checksum, package_result, auth)

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
      Release held for approval; after the owner approves, dispatch again from main with the same release_commit.
      The next dispatch uploads only what is missing and reads both archives back.
      """)

      System.halt(1)
    end

    if :error in [package_result, docs_result], do: System.halt(1)
  end

  defp served_release(version, checksum) do
    # The public release endpoint advertises a 60-second cache lifetime.
    config =
      Hex.API.Client.build_config(nil, [])
      |> Map.update!(:http_headers, &Map.put(&1, "cache-control", "no-cache"))

    case :mix_hex_api_release.get(config, "ash_hooks", version) do
      {:ok, {404, _headers, _body}} ->
        :missing

      {:ok, {200, _headers, %{"version" => ^version, "retirement" => nil} = release}} ->
        unless release["checksum"] == checksum do
          Mix.raise("Hex serves ash_hooks #{version} with other package bytes")
        end

        has_docs = release["has_docs"]
        unless is_boolean(has_docs), do: Mix.raise("Hex returned no definite documentation state")
        {:served, has_docs}

      _ ->
        Mix.raise("Could not confirm an unretired Hex release for ash_hooks #{version}")
    end
  end

  defp publish_package(version, package, checksum, auth) do
    result =
      upload("package", package, fn ->
        Hex.API.Release.publish(nil, package, auth, fn _ -> :ok end, replace: false)
      end)

    # A request may lose its response or race the publication of identical bytes.
    if result == :error and match?({:served, _}, served_release(version, checksum)) do
      skip("package")
    else
      result
    end
  end

  defp publish_docs("skip", _version, _docs, _checksum, _package_result, _auth), do: :ok

  defp publish_docs("upload", version, docs, checksum, package_result, auth) do
    # Hex's docs API has no replace guard. Recheck the package identity and docs
    # state just before the request. An explicitly staged package can accept docs
    # before it is served.
    staged_package? = match?({:staged, _}, package_result)

    case served_release(version, checksum) do
      {:served, true} ->
        skip("docs")

      :missing when not staged_package? ->
        Mix.raise("Hex does not serve the checked package yet; retry the upload")

      _ ->
        upload("docs", docs, fn ->
          Hex.API.ReleaseDocs.publish(nil, "ash_hooks", version, docs, auth)
        end)
    end
  end

  defp skip(kind) do
    IO.puts("#{kind}: already served; upload skipped")
    :ok
  end

  defp upload(kind, archive, request) do
    case request.() do
      {:ok, {status, _headers, %{"status" => "staged"} = staged}}
      when status in 200..299 ->
        IO.puts("#{kind}: held for approval")

        for field <- ["kind", "html_url", "expires_at"] do
          value = staged[field] || if(field == "kind", do: kind, else: "unspecified")
          value = if is_binary(value), do: Hex.Utils.printable_ascii(value), else: "unspecified"
          IO.puts("#{field}: #{value}")
        end

        IO.puts("SHA-256: #{digest(archive)}")
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

  defp digest(archive), do: :crypto.hash(:sha256, archive) |> Base.encode16(case: :lower)
end

PublishHexRelease.run()
