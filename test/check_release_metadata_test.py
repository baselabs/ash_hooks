"""Check the release version and metadata without loading a Mix project."""

import json
from pathlib import Path
import runpy
import subprocess
from tempfile import TemporaryDirectory
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
COMMIT = "a" * 40
VERSION = "3.7.0"


class ReleaseMetadataTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.docs = runpy.run_path(str(SCRIPTS / "check-docs-archive.py"))
        cls.state = runpy.run_path(str(SCRIPTS / "hex-release-state.py"))

    def test_docs_marker_requires_unique_fields(self):
        record = {"package": "ash_hooks", "version": VERSION, "commit": COMMIT}
        marker = json.dumps(record).encode()
        self.assertEqual(self.docs["release"](marker, VERSION), COMMIT)
        for key in record:
            with self.subTest(key=key):
                duplicate = f'{{"{key}":"wrong",'.encode() + marker[1:]
                with self.assertRaisesRegex(ValueError, "release.json has duplicate fields"):
                    self.docs["release"](duplicate, VERSION)

    def test_hex_response_requires_unique_fields_at_every_depth(self):
        self.assertEqual(self.state["object_body"](b'{"retirement":null}'), {"retirement": None})
        for response in (
            b'{"retirement":{"reason":"deprecated"},"retirement":null}',
            b'{"has_docs":true,"has_docs":false}',
            b'{"meta":{"app":"wrong","app":"ash_hooks"}}',
        ):
            with self.subTest(response=response):
                with self.assertRaisesRegex(ValueError, "duplicate release fields"):
                    self.state["object_body"](response)

    def read_version(self, body):
        return self.read_version_source(f"defmodule Candidate do\n{body}\nend\n".encode())

    def read_version_source(self, source):
        with TemporaryDirectory(prefix="ash-hooks-mix-version-") as directory:
            project = Path(directory) / "mix.exs"
            project.write_bytes(source)
            return subprocess.run(
                ["elixir", SCRIPTS / "read-mix-version.exs", project],
                cwd=SCRIPTS.parent, capture_output=True, text=True, timeout=20,
            )

    def test_indentation_comments_and_reads_do_not_add_assignments(self):
        result = self.read_version(
            '  # @version "1.0.0"\n'
            '    @version "3.7.0" # release\n'
            '  def current, do: @version\n'
            '  @description "example: @version 9.9.9"\n'
            '  @moduledoc """\n  @version "9.9.9"\n  """\n'
            '  raise "the project must never be evaluated"'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f"{VERSION}\n")

    def test_second_assignment_is_refused_at_any_indentation(self):
        for declaration in (
            '    @version "3.8.0"',
            '\t@version "3.8.0"',
            '  @version System.get_env("VERSION")',
            '  if true, do: @version("3.8.0")',
            '  Kernel.@(version("9.9.9"))',
            '  quote do\n    @version "9.9.9"\n  end',
            '  defmodule Nested do\n    @version "9.9.9"\n  end',
        ):
            with self.subTest(declaration=declaration):
                result = self.read_version('  @version "3.7.0"\n' + declaration)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("exactly one string-literal @version", result.stderr)

    def test_missing_or_computed_version_is_refused(self):
        for declaration in (
            '',
            '  @version System.get_env("VERSION")',
            '  @version "3.7.#{0}"',
            '  @version "3.7." <> "0"',
            '  @version ~s(3.7.0)',
            "  @version '3.7.0'",
            '  quote do\n    @version unquote(candidate)\n  end',
        ):
            with self.subTest(declaration=declaration):
                result = self.read_version(declaration)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("exactly one string-literal @version", result.stderr)

    def test_heredoc_trailing_newline_is_not_a_semantic_version(self):
        result = self.read_version('  @version """\n  3.7.0\n  """')
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("semantic Mix project version", result.stderr)

    def test_kernel_attribute_accepts_one_literal_assignment(self):
        for declaration in (
            '  Kernel.@(version("3.7.0"))',
            '  Elixir.Kernel.@(version("3.7.0"))',
        ):
            with self.subTest(declaration=declaration):
                result = self.read_version(declaration)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, f"{VERSION}\n")

    def test_module_api_cannot_put_or_register_version(self):
        for declaration in (
            '  Module.put_attribute(__MODULE__, :version, "9.9.9")',
            '  Module.register_attribute(__MODULE__, :version, accumulate: true)',
            '  Elixir.Module.put_attribute(__MODULE__, :version, "9.9.9")',
        ):
            with self.subTest(declaration=declaration):
                result = self.read_version('  @version "3.7.0"\n' + declaration)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("Module APIs must not set or register @version", result.stderr)

    def test_invalid_source_encoding_is_refused_without_a_stack_trace(self):
        source = b'defmodule Candidate do\n  @version "3.7.0"\nend\n'
        for encoded, message in (
            (source + b"# \xff\n", "mix.exs must be valid UTF-8"),
            (b"\xef\xbb\xbf" + source, "mix.exs must not start with a UTF-8 BOM"),
        ):
            with self.subTest(message=message):
                result = self.read_version_source(encoded)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertEqual(result.stderr.strip(), message)


if __name__ == "__main__":
    unittest.main()
