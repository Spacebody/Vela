from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "ReleaseCandidate/scripts/validate_app_resources.py"


def run(root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), "--repository-root", str(root)],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )


class AppResourceBindingTests(unittest.TestCase):
    def test_checked_in_app_resources_match_frozen_sources(self) -> None:
        result = run(ROOT)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_public_contract_resource_byte_drift_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            temporary = Path(raw)
            relative_files = (
                "Contracts/v1/public-contract-freeze.json",
                "Contracts/v1/hashes.json",
                "Hardening/config/architecture-freeze.json",
                "ReleaseCandidate/config/known-limitations.json",
                "Vela/Resources/ReleaseCandidate/baseline.json",
                "Vela/Resources/ReleaseCandidate/public-contract-freeze.json",
                "Vela/Resources/ReleaseCandidate/known-limitations.json",
            )
            for relative in relative_files:
                destination = temporary / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / relative, destination)
            bundled = temporary / "Vela/Resources/ReleaseCandidate/public-contract-freeze.json"
            bundled.write_bytes(bundled.read_bytes() + b"\n")
            result = run(temporary)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("resource drifted", result.stderr)


if __name__ == "__main__":
    unittest.main()
