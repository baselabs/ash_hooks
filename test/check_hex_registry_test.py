"""Exercise the registry check against real signed records from repo.hex.pm."""

import gzip
from pathlib import Path
import subprocess
import sys
import unittest
from urllib.request import urlopen

CHECKER = Path(__file__).resolve().parents[1] / "scripts/check-hex-registry.py"
CHECKSUM_370 = "15a7216032e726291a13cc79f5bc3988431f01eacb736adefb1cc6594e7f74dd"
CHECKSUM_360 = "e0d7c34e3d9219f3dc6c8a5bb025d55582c194a8d826d0736237d4b452eecf1f"


class HexRegistryTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with urlopen("https://repo.hex.pm/packages/ash_hooks", timeout=20) as response:
            cls.snapshot = response.read()

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


if __name__ == "__main__":
    unittest.main()
