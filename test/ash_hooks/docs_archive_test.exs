defmodule AshHooks.DocsArchiveTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/check-docs-archive.py", __DIR__)
  @writer """
  import base64, io, sys, tarfile
  path, rest = sys.argv[1], sys.argv[2:]
  with tarfile.open(path, "w:gz") as packed:
      for name, data in zip(rest[::2], rest[1::2]):
          info = tarfile.TarInfo(name)
          content = base64.b64decode(data)
          info.size = len(content)
          packed.addfile(info, io.BytesIO(content))
  """

  setup do
    tree = Path.join(System.tmp_dir!(), "docs_archive_#{Ash.UUID.generate()}")
    docs = Path.join(tree, "doc")
    File.mkdir_p!(Path.join(docs, "dist"))
    File.mkdir_p!(Path.join(docs, ".hidden"))
    on_exit(fn -> File.rm_rf!(tree) end)
    File.write!(Path.join(docs, "index.html"), "index")
    File.write!(Path.join(docs, "readme.html"), "readme")
    File.write!(Path.join(docs, "readme.md"), "readme")
    File.write!(Path.join(docs, "dist/app.js"), "app")
    # mix hex.publish leaves names that start with a dot out of the archive.
    File.write!(Path.join(docs, ".build"), "manifest")
    File.write!(Path.join(docs, ".hidden/page.html"), "hidden")
    %{tree: tree, docs: docs}
  end

  test "an archive of exactly the tree's visible regular files passes", context do
    {output, status} = check(context, archive(context, members(context)))
    assert status == 0, output
    assert output =~ "DOCS OK: 4 regular files"
    assert output =~ ~r/SHA256: [0-9a-f]{64}/
  end

  test "an EPUB is refused because it embeds the build time", context do
    File.write!(Path.join(context.docs, "AshHooks.epub"), "book")
    entries = members(context) ++ [{"AshHooks.epub", "book"}]
    {output, status} = check(context, archive(context, entries))
    assert status == 1
    assert output =~ "EPUB embeds the build time"
  end

  test "differing bytes, omitted files, extra and unsafe members are refused", context do
    cases = [
      {[{"index.html", "other"} | tl(members(context))], "bytes differ from source"},
      {Enum.drop(members(context), -1), "omits source files"},
      {[{".build", "manifest"} | members(context)], "has no source"},
      {[{"../index.html", "index"} | members(context)], "Unsafe docs archive member"},
      {[{"3.4.0/index.html", "index"} | members(context)], "cannot be semantic versions"},
      {[{"index.html", "index"} | members(context)], "Duplicate docs archive member"}
    ]

    for {entries, message} <- cases do
      {output, status} = check(context, archive(context, entries))
      assert status == 1, message
      assert output =~ message
    end
  end

  test "a served archive passes with its entry pages, an EPUB or other bytes", context do
    entries = [{"AshHooks.epub", "book"}, {"index.html", "rebuilt"} | tl(members(context))]
    {output, status} = served(archive(context, entries))
    assert status == 0, output
    assert output =~ "DOCS OK: 5 regular files served, entry pages present"
    assert output =~ ~r/SHA256: [0-9a-f]{64}/
  end

  test "a served archive without entry pages or with unsafe members is refused", context do
    cases = [
      {Enum.reject(members(context), &(elem(&1, 0) == "readme.html")), "requires top-level"},
      {[{"../index.html", "index"} | members(context)], "Unsafe docs archive member"},
      {[{"index.html", "index"} | members(context)], "Duplicate docs archive member"}
    ]

    for {entries, message} <- cases do
      {output, status} = served(archive(context, entries))
      assert status == 1, message
      assert output =~ message
    end
  end

  defp members(%{docs: docs}) do
    for name <- ["index.html", "readme.html", "readme.md", "dist/app.js"],
        do: {name, File.read!(Path.join(docs, name))}
  end

  # Python's tarfile writes every member name as given, including the unsafe
  # and duplicate names the checker must refuse.
  defp archive(%{tree: tree}, entries) do
    path = Path.join(tree, "docs-#{System.unique_integer([:positive])}.tar.gz")

    args = Enum.flat_map(entries, fn {name, bytes} -> [name, Base.encode64(bytes)] end)

    {output, status} =
      System.cmd("python3", ["-I", "-c", @writer, path | args], stderr_to_stdout: true)

    assert status == 0, output
    path
  end

  defp check(%{docs: docs}, archive),
    do: System.cmd("python3", ["-I", @script, archive, docs], stderr_to_stdout: true)

  defp served(archive),
    do: System.cmd("python3", ["-I", @script, "--served", archive], stderr_to_stdout: true)
end
