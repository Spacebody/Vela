from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VALIDATOR = ROOT / "Release/scripts/validate_release_notes.py"
FIXTURES = ROOT / "Release/config/fixtures"


class ReleaseNotesTests(unittest.TestCase):
    def run_notes(self, filename: str, candidate: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(VALIDATOR),
                str(FIXTURES / filename),
                "--candidate-version",
                candidate,
                "--production",
            ],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_accepts_exact_rc_candidate_title_and_sections(self) -> None:
        result = self.run_notes("release-notes-1.0.0-rc.1.md", "1.0.0-rc.1")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_accepts_exact_stable_candidate_title_and_sections(self) -> None:
        result = self.run_notes("release-notes-1.0.0.md", "1.0.0")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_notes_for_a_different_rc_sequence(self) -> None:
        result = self.run_notes("release-notes-1.0.0-rc.1.md", "1.0.0-rc.2")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("# Vela 1.0.0 RC 2", result.stderr)

    def test_rejects_noncanonical_rc_semver(self) -> None:
        result = self.run_notes("release-notes-1.0.0-rc.1.md", "1.0.0-rc.01")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exact rc.N", result.stderr)


if __name__ == "__main__":
    unittest.main()
