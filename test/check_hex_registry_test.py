"""Exercise the Hex registry check with live signed and synthetic records."""

import gzip
from io import BytesIO
from pathlib import Path
import runpy
import subprocess
import sys
from time import sleep
import unittest
from urllib.error import HTTPError
from urllib.request import urlopen

CHECKER = Path(__file__).resolve().parents[1] / "scripts/check-hex-registry.py"
CHECKSUM_370 = "15a7216032e726291a13cc79f5bc3988431f01eacb736adefb1cc6594e7f74dd"
CHECKSUM_360 = "e0d7c34e3d9219f3dc6c8a5bb025d55582c194a8d826d0736237d4b452eecf1f"
# https://hex.pm/api/packages/ash_hooks/releases/2.3.0
CHECKSUM_230 = "cd3361e89665b8f6f7af008a922b8eec73576444b7995627f7fb222591465887"


class HexRegistryTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for attempt in range(3):
            try:
                with urlopen("https://repo.hex.pm/packages/ash_hooks", timeout=20) as response:
                    cls.snapshot = response.read()
                return
            except OSError as error:
                if isinstance(error, HTTPError):
                    error.close()
                    if error.code != 429 and not 500 <= error.code < 600:
                        raise
                if attempt == 2:
                    raise
                sleep(0.5 * (attempt + 1))

    def check(self, version, checksum, snapshot=None):
        return subprocess.run(
            [sys.executable, "-I", CHECKER, version, checksum],
            input=self.snapshot if snapshot is None else snapshot,
            capture_output=True, timeout=15,
        )

    def test_published_releases_match(self):
        for version, checksum in (("3.7.0", CHECKSUM_370), ("3.6.0", CHECKSUM_360)):
            with self.subTest(version=version):
                result = self.check(version, checksum)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_tampered_payload_fails_signature_verification(self):
        signed = gzip.decompress(self.snapshot)
        self.assertIn(b"ash_hooks", signed)
        tampered = gzip.compress(signed.replace(b"ash_hooks", b"ash_h00ks", 1))
        result = self.check("3.7.0", CHECKSUM_370, tampered)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"signature verification failed", result.stderr)

    def test_absent_version_fails(self):
        result = self.check("0.0.0-not-published", CHECKSUM_370)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"expected exactly one registry release", result.stderr)

    def test_checksum_of_another_release_fails(self):
        result = self.check("3.7.0", CHECKSUM_360)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"outer checksum differs", result.stderr)

    def test_retired_release_fails_even_with_its_real_checksum(self):
        result = self.check("2.3.0", CHECKSUM_230)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"retired ash_hooks 2.3.0", result.stderr)


def bytes_field(number, value):
    return bytes([number << 3 | 2, len(value)]) + value


class HexRegistryParserTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.parser = runpy.run_path(str(CHECKER))

    def setUp(self):
        self.checksum = bytes.fromhex(CHECKSUM_370)
        self.release = bytes_field(1, b"3.7.0") + bytes_field(5, self.checksum)

    def payload(self, releases, name=b"ash_hooks", repository=b"hexpm"):
        return b"".join(bytes_field(1, release) for release in releases) + (
            bytes_field(2, name) + bytes_field(3, repository)
        )

    def test_duplicate_version_records_fail(self):
        payload = self.payload([self.release, self.release])
        with self.assertRaisesRegex(ValueError, "expected exactly one registry release"):
            self.parser["check_package"](payload, "3.7.0", self.checksum)

    def test_wrong_package_identity_fails(self):
        for name, repository in ((b"other_package", b"hexpm"), (b"ash_hooks", b"other_repo")):
            with self.subTest(name=name, repository=repository):
                payload = self.payload([self.release], name=name, repository=repository)
                with self.assertRaisesRegex(ValueError, "does not name hexpm/ash_hooks"):
                    self.parser["check_package"](payload, "3.7.0", self.checksum)

    def test_truncated_varint_fails(self):
        with self.assertRaisesRegex(ValueError, "invalid protobuf varint"):
            self.parser["fields"](b"\x0a\x80")

    def test_overlong_varint_fails(self):
        with self.assertRaisesRegex(ValueError, "invalid protobuf varint"):
            self.parser["fields"](b"\x0a" + b"\x80" * 10 + b"\x00")

    def test_unsupported_wire_type_fails(self):
        with self.assertRaisesRegex(ValueError, "unsupported protobuf wire type"):
            self.parser["fields"](b"\x0b")

    def test_oversized_registry_fails(self):
        data = gzip.compress(bytes(self.parser["MAX_REGISTRY_SIZE"] + 1))
        with self.assertRaisesRegex(ValueError, "exceeds the uncompressed size limit"):
            self.parser["check"](BytesIO(data), "3.7.0", self.checksum)

    def test_retired_record_fails(self):
        retired = self.release + bytes_field(4, b"\x08\x04")
        with self.assertRaisesRegex(ValueError, "retired ash_hooks 3.7.0"):
            self.parser["check_package"](self.payload([retired]), "3.7.0", self.checksum)


if __name__ == "__main__":
    unittest.main()
