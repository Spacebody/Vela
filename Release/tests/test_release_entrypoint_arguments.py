from __future__ import annotations

import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Release/scripts/release.sh"


class ReleaseEntrypointArgumentTests(unittest.TestCase):
    def run_script(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            (str(SCRIPT), *arguments),
            cwd=ROOT,
            text=True,
            capture_output=True,
        )

    def test_rejects_duplicate_value_option(self) -> None:
        result = self.run_script("--config", "first.json", "--config", "second.json")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("option may be specified only once: --config", result.stderr)

    def test_rejects_conflicting_mode_options(self) -> None:
        result = self.run_script("--execute", "--dry-run")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("option may be specified only once: --mode", result.stderr)

    def test_rejects_conflicting_phase_options(self) -> None:
        result = self.run_script("--stage-candidate", "--promote-candidate")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("option may be specified only once: --phase", result.stderr)

    def test_rejects_missing_option_value(self) -> None:
        result = self.run_script("--version")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("option requires a value: --version", result.stderr)


if __name__ == "__main__":
    unittest.main()
