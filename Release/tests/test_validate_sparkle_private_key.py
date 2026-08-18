from __future__ import annotations

import base64
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VALIDATOR = ROOT / "Release/scripts/validate_sparkle_private_key.py"


class SparklePrivateKeyTests(unittest.TestCase):
    def run_key(self, decoded_size: int) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as raw:
            key = Path(raw) / "sparkle.key"
            key.write_text(
                base64.b64encode(bytes((index % 251) + 1 for index in range(decoded_size))).decode("ascii") + "\n",
                encoding="utf-8",
            )
            return subprocess.run(
                [sys.executable, str(VALIDATOR), str(key)],
                capture_output=True,
                text=True,
                check=False,
            )

    def test_accepts_sparkle_current_64_byte_key(self) -> None:
        result = self.run_key(64)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_accepts_sparkle_legacy_96_byte_key(self) -> None:
        result = self.run_key(96)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_raw_32_byte_seed(self) -> None:
        result = self.run_key(32)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("64-byte key or 96-byte legacy key", result.stderr)


if __name__ == "__main__":
    unittest.main()
