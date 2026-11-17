defmodule AshHooks.PublicationDashesTest do
  use ExUnit.Case, async: false

  @script Path.expand("../../scripts/check-document-dashes.py", __DIR__)

  test "both dashes fail in archives, HTML and EPUB but repository-only text passes" do
    tree = Path.join(System.tmp_dir!(), "publication_dashes_#{Ash.UUID.generate()}")
    File.mkdir_p!(tree)
    on_exit(fn -> File.rm_rf!(tree) end)

    for codepoint <- [0x2013, 0x2014], surface <- ["package", "html", "epub", "repository"] do
      {output, status} =
        System.cmd("python3", ["-c", fixture(), tree, surface, Integer.to_string(codepoint)],
          stderr_to_stdout: true
        )

      assert status == 0, output

      {output, status} =
        System.cmd(
          "python3",
          [
            @script,
            "--package",
            Path.join(tree, "package.tar"),
            "--docs",
            Path.join(tree, "docs")
          ],
          stderr_to_stdout: true
        )

      if surface == "repository" do
        assert {output, status} == {"", 0}
      else
        assert status == 1
        assert output =~ ":2"
        refute output =~ <<codepoint::utf8>>
      end
    end
  end

  test "only ExDoc's final project separator is exempt from generated HTML" do
    tree = Path.join(System.tmp_dir!(), "publication_template_#{Ash.UUID.generate()}")
    File.mkdir_p!(tree)
    on_exit(fn -> File.rm_rf!(tree) end)
    page = Path.join(tree, "page.html")
    dash = <<0x2014::utf8>>
    project = ~s(<meta name="project" content="AshHooks v3.2.0">)
    title = "<title>Guide #{dash} AshHooks v3.2.0</title>"
    original = "#{project}\n#{title}\n<body>plain</body>"
    File.write!(page, original)
    assert {"", 0} = System.cmd("python3", [@script, "--docs", tree], stderr_to_stdout: true)

    assert File.read!(page) == original

    for codepoint <- [0x2013, 0x2014], label <- ["AshHooks.Module", "An extra title"] do
      authored = <<codepoint::utf8>>
      title = "<title>#{label} #{authored} text #{dash} AshHooks v3.2.0</title>"
      File.write!(page, "#{project}\n#{title}\n<body>#{authored}</body>")
      {output, status} = System.cmd("python3", [@script, "--docs", tree], stderr_to_stdout: true)
      assert status == 1
      assert output =~ "#{page}:2"
      assert output =~ "#{page}:3"
      refute output =~ authored
    end

    for title <- [
          "<title>Guide #{dash} OtherProject v3.2.0</title>",
          "<title>Guide #{dash} AshHooks v0.0.0</title>",
          "<title>Guide #{dash} AshHooks v3.2.0 suffix</title>",
          "<title>AshHooks v3.2.0 #{dash} Documentation</title>"
        ] do
      File.write!(page, "#{project}\n#{title}")
      {output, status} = System.cmd("python3", [@script, "--docs", tree], stderr_to_stdout: true)
      assert status == 1
      assert output =~ "#{page}:2"
    end
  end

  test "the HTML template exception does not exempt an EPUB member" do
    tree = Path.join(System.tmp_dir!(), "publication_epub_#{Ash.UUID.generate()}")
    File.mkdir_p!(tree)
    on_exit(fn -> File.rm_rf!(tree) end)
    archive = Path.join(tree, "guide.epub")
    dash = <<0x2014::utf8>>
    project = ~s(<meta name="project" content="AshHooks v3.2.0">)
    title = "<title>Guide #{dash} AshHooks v3.2.0</title>"

    assert {:ok, _} =
             :zip.create(String.to_charlist(archive), [
               {~c"chapter.xhtml", "#{project}\n#{title}"}
             ])

    {output, status} = System.cmd("python3", [@script, "--docs", tree], stderr_to_stdout: true)
    assert status == 1
    assert output =~ "#{archive}/chapter.xhtml:2"
  end

  defp fixture do
    ~S"""
    import io, pathlib, sys, tarfile, zipfile
    root, surface, codepoint = pathlib.Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
    text = ("first\ntext " + chr(codepoint) + " here\n").encode()
    clean = b"first\nplain text\n"
    contents = io.BytesIO()
    with tarfile.open(fileobj=contents, mode="w:gz") as archive:
        data = text if surface == "package" else clean
        member = tarfile.TarInfo("lib/example.ex")
        member.size = len(data)
        archive.addfile(member, io.BytesIO(data))
    with tarfile.open(root / "package.tar", "w") as archive:
        data = contents.getvalue()
        member = tarfile.TarInfo("contents.tar.gz")
        member.size = len(data)
        archive.addfile(member, io.BytesIO(data))
    docs = root / "docs"
    docs.mkdir(exist_ok=True)
    (docs / ".build.epub").write_text("reference.epub\n")
    (docs / "index.html").write_bytes(text if surface == "html" else clean)
    with zipfile.ZipFile(docs / "reference.epub", "w") as book:
        book.writestr("EPUB/index.xhtml", text if surface == "epub" else clean)
    (root / "repository-only.txt").write_bytes(text)
    """
  end
end
