from __future__ import annotations

import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "ReleaseCandidate/scripts/manage_build_ledger.py"
SOURCE = ROOT / "ReleaseCandidate/config/published-builds.json"


def run(*arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ("python3", str(SCRIPT), *arguments),
        cwd=ROOT,
        text=True,
        capture_output=True,
    )


class ProtectedBuildLedgerTests(unittest.TestCase):
    def ledger(self, directory: Path) -> Path:
        path = directory / "published-builds.json"
        path.write_bytes(SOURCE.read_bytes())
        path.chmod(0o600)
        return path

    def test_reservation_is_atomic_and_build_number_is_never_reused(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            ledger = self.ledger(Path(raw))
            arguments = (
                "--ledger", str(ledger), "reserve",
                "--version", "1.0.0-rc.1",
                "--marketing-version", "1.0.0",
                "--build", "2026071501",
                "--channel", "rc",
            )
            first = run(*arguments)
            second = run(*arguments)
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertNotEqual(second.returncode, 0)
            value = json.loads(ledger.read_text(encoding="utf-8"))
            self.assertEqual(len(value["builds"]), 1)
            self.assertEqual(value["builds"][0]["status"], "allocated")
            self.assertEqual(ledger.stat().st_mode & 0o777, 0o600)

    def test_failed_allocation_consumes_build_but_not_version(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            ledger = self.ledger(Path(raw))
            base = ("--ledger", str(ledger))
            reserved = run(
                *base, "reserve", "--version", "1.0.0", "--build", "2026071501",
                "--channel", "stable",
            )
            failed = run(
                *base, "finalize", "--version", "1.0.0", "--build", "2026071501",
                "--channel", "stable", "--status", "failed",
            )
            retry = run(
                *base, "reserve", "--version", "1.0.0", "--build", "2026071502",
                "--channel", "stable",
            )
            self.assertEqual(reserved.returncode, 0, reserved.stderr)
            self.assertEqual(failed.returncode, 0, failed.stderr)
            self.assertEqual(retry.returncode, 0, retry.stderr)
            value = json.loads(ledger.read_text(encoding="utf-8"))
            self.assertEqual([row["status"] for row in value["builds"]], ["failed", "allocated"])

    def test_published_transition_requires_digest_and_is_final(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            ledger = self.ledger(Path(raw))
            base = ("--ledger", str(ledger))
            self.assertEqual(run(
                *base, "reserve", "--version", "1.0.0", "--build", "2026071501",
                "--channel", "stable",
            ).returncode, 0)
            missing = run(
                *base, "finalize", "--version", "1.0.0", "--build", "2026071501",
                "--channel", "stable", "--status", "published",
            )
            digest = hashlib.sha256(b"immutable public artifact").hexdigest()
            published = run(
                *base, "finalize", "--version", "1.0.0", "--build", "2026071501",
                "--channel", "stable", "--status", "published", "--artifact-sha256", digest,
            )
            reissue = run(
                *base, "reserve", "--version", "1.0.0", "--build", "2026071502",
                "--channel", "stable",
            )
            self.assertNotEqual(missing.returncode, 0)
            self.assertEqual(published.returncode, 0, published.stderr)
            self.assertNotEqual(reissue.returncode, 0)

    def test_unsafe_permissions_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            ledger = self.ledger(Path(raw))
            ledger.chmod(0o644)
            result = run(
                "--ledger", str(ledger), "reserve", "--version", "1.0.0-rc.1",
                "--build", "2026071501", "--channel", "rc",
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("permissions must be 0600", result.stderr)

    def test_reserved_candidate_gate_requires_exact_high_water_identity(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            ledger = self.ledger(Path(raw))
            base = ("--ledger", str(ledger))
            self.assertEqual(run(
                *base, "reserve", "--version", "1.0.0-rc.1", "--build", "2026071501",
                "--channel", "rc",
            ).returncode, 0)
            validator = ROOT / "ReleaseCandidate/scripts/validate_semver_build.py"
            exact = subprocess.run(
                (
                    "python3", str(validator), "--version", "1.0.0-rc.1",
                    "--build", "2026071501", "--channel", "rc",
                    "--published", str(ledger), "--expect-reserved",
                ),
                cwd=ROOT, text=True, capture_output=True,
            )
            wrong_version = subprocess.run(
                (
                    "python3", str(validator), "--version", "1.0.0-rc.2",
                    "--build", "2026071501", "--channel", "rc",
                    "--published", str(ledger), "--expect-reserved",
                ),
                cwd=ROOT, text=True, capture_output=True,
            )
            self.assertEqual(exact.returncode, 0, exact.stderr)
            self.assertNotEqual(wrong_version.returncode, 0)

    def test_active_version_cannot_receive_a_second_build_allocation(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            ledger = self.ledger(Path(raw))
            base = ("--ledger", str(ledger))
            first = run(
                *base, "reserve", "--version", "1.0.0-rc.1", "--build", "2026071501",
                "--channel", "rc",
            )
            second = run(
                *base, "reserve", "--version", "1.0.0-rc.1", "--build", "2026071502",
                "--channel", "rc",
            )
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertNotEqual(second.returncode, 0)
            self.assertIn("active build allocation", second.stderr)

    def test_published_build_can_only_withdraw_the_same_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            ledger = self.ledger(Path(raw))
            base = ("--ledger", str(ledger))
            digest = hashlib.sha256(b"published bytes").hexdigest()
            replacement = hashlib.sha256(b"different bytes").hexdigest()
            self.assertEqual(run(
                *base, "reserve", "--version", "1.0.0", "--build", "2026071501",
                "--channel", "stable",
            ).returncode, 0)
            self.assertEqual(run(
                *base, "finalize", "--version", "1.0.0", "--build", "2026071501",
                "--channel", "stable", "--status", "published",
                "--artifact-sha256", digest,
            ).returncode, 0)
            replaced = run(
                *base, "finalize", "--version", "1.0.0", "--build", "2026071501",
                "--channel", "stable", "--status", "withdrawn",
                "--artifact-sha256", replacement,
            )
            withdrawn = run(
                *base, "finalize", "--version", "1.0.0", "--build", "2026071501",
                "--channel", "stable", "--status", "withdrawn",
                "--artifact-sha256", digest,
            )
            self.assertNotEqual(replaced.returncode, 0)
            self.assertIn("preserve the exact published artifact", replaced.stderr)
            self.assertEqual(withdrawn.returncode, 0, withdrawn.stderr)


if __name__ == "__main__":
    unittest.main()
