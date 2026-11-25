unless is_nil(Mix.Project.get()) do
  Mix.raise("Release uploads must run outside a Mix project")
end

defmodule PublishHexRelease do
  def run do
    [version, package_path, docs_path, package_plan, docs_plan] = System.argv()
    plan = {package_plan, docs_plan}

    unless match?({:ok, _}, Version.parse(version)) and
             plan in [{"upload", "upload"}, {"skip", "upload"}, {"skip", "skip"}] do
      Mix.raise("Expected a release version and a valid package and docs upload plan")
    end

    package = File.read!(package_path)
    docs = File.read!(docs_path)
    checksum = digest(package)
    Hex.start()
    Code.ensure_loaded!(Hex.API.Release)
    Code.ensure_loaded!(Hex.API.ReleaseDocs)

    package_result =
      case {package_plan, served_release(version, checksum)} do
        {_, {:served, _}} ->
          skip("package")

        {"upload", :missing} ->
          publish_package(version, package, checksum)

        {"skip", :missing} ->
          Mix.raise("Hex no longer serves the package that the build planned to keep")
      end

    if package_result == :error, do: System.halt(1)

    docs_result = publish_docs(docs_plan, version, docs, checksum, package_result)

    if Enum.any?([package_result, docs_result], &match?({:staged, _}, &1)) do
      IO.puts(:stderr, """
      Hex has staged the remaining release assets. After the owner approves on hex.pm,
      the release maintainer dispatches once more from main with the same release_commit to read both archives back.
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

  defp publish_package(version, package, checksum) do
    auth = upload_auth()

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

  defp publish_docs("upload", version, docs, checksum, {:staged, package}) do
    url = package["url"]

    unless package["kind"] == "release" and package["checksum"] == checksum and is_binary(url) do
      Mix.raise("Hex did not return a staged receipt and status URL for the inspected package")
    end

    auth = upload_auth()

    unless served_release(version, checksum) == :missing do
      Mix.raise("Hex already serves ash_hooks #{version}; staged docs were not posted")
    end

    # Read the stage with the staging credential. Hex can still approve it
    # between this read and the unconditional docs POST.
    case Hex.API.Release.get_staged(url, auth) do
      {:ok,
       {200, _headers,
        %{
          "name" => "ash_hooks",
          "version" => ^version,
          "status" => "staged",
          "kind" => "release",
          "checksum" => ^checksum
        }}} ->
        :ok

      _ ->
        Mix.raise(
          "Hex did not confirm an active stage for the inspected package. Docs were not posted."
        )
    end

    case upload_docs(version, docs, auth) do
      {:staged, %{"kind" => "release", "checksum" => ^checksum}} = result ->
        result

      _ ->
        Mix.raise("Hex did not attach docs to the staged package")
    end
  end

  defp publish_docs(plan, version, docs, checksum, _package_result) do
    # The server's DocsController.create calls Releases.publish_docs without a
    # precondition:
    # https://github.com/hexpm/hexpm/blob/5e638200c2b1fbdb3412e18c7b433071ade3305e/lib/hexpm_web/controllers/api/docs_controller.ex#L101-L119
    # publish_docs_now writes to the existing docs path:
    # https://github.com/hexpm/hexpm/blob/5e638200c2b1fbdb3412e18c7b433071ade3305e/lib/hexpm/repository/releases.ex#L326-L344
    # Hex 2.7.0 sends an unconditional POST:
    # https://github.com/hexpm/hex/blob/92cb6a1b10c9b008ccb6fa229f5d9916840dc09d/lib/hex/api/release_docs.ex#L24-L53
    # Another publisher can still change the release or write docs between this
    # checksum and has_docs check and the POST.
    case {plan, served_release(version, checksum)} do
      {_, {:served, true}} ->
        skip("docs")

      {"skip", _} ->
        Mix.raise("Hex no longer serves the docs that the build planned to keep")

      {"upload", :missing} ->
        Mix.raise("Hex does not serve the checked package yet; retry the upload")

      {"upload", {:served, false}} ->
        upload_docs(version, docs, upload_auth())
    end
  end

  defp upload_docs(version, docs, auth) do
    upload("docs", docs, fn ->
      Hex.API.ReleaseDocs.publish(nil, "ash_hooks", version, docs, auth)
    end)
  end

  defp upload_auth do
    key = System.fetch_env!("HEX_API_KEY")
    if String.trim(key) == "", do: Mix.raise("HEX_API_KEY is empty")
    [key: key]
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
