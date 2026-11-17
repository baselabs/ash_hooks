defmodule AshHooks.PublicationDashesTest do
  use ExUnit.Case, async: false

  @script Path.expand("../../scripts/check-document-dashes.py", __DIR__)

  test "both dashes fail in archives, HTML and EPUB but repository-only text passes" do
    tree = Path.join(System.tmp_dir!(), "publication_dashes_#{Ash.UUID.generate()}")
    File.mkdir_p!(tree)
    on_exit(fn -> File.rm_rf!(tree) end)

    for codepoint <- [0x2013, 0x2014], surface <- ["package", "html", "epub", "repository"] do
      {output, status} = System.cmd("python3", ["-c", fixture(), tree, surface, Integer.to_string(codepoint)], stderr_to_stdout: true)
      assert status == 0, output

      {output, status} = System.cmd("python3", [@script, "--package", Path.join(tree, "package.tar"), "--docs", Path.join(tree, "docs")], stderr_to_stdout: true)
      if surface == "repository" do
        assert {output, status} == {"", 0}
      else
        assert status == 1
        assert output =~ ":2"
        refute output =~ <<codepoint::utf8>>
      end
    end
  end

  defp fixture do
    """
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
    (docs / "index.html").write_bytes(text if surface == "html" else clean)
    with zipfile.ZipFile(docs / "reference.epub", "w") as book:
        book.writestr("EPUB/index.xhtml", text if surface == "epub" else clean)
    (root / "repository-only.txt").write_bytes(text)
    """
  end
end
