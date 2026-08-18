from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
IDENTITY = ROOT / "ReleaseCandidate/scripts/validate_source_build_identity.py"
TREE = ROOT / "ReleaseCandidate/scripts/validate_candidate_stage_tree.py"


def run(script: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        (sys.executable, str(script), *arguments),
        cwd=ROOT,
        text=True,
        capture_output=True,
    )


class ReleaseSourceIdentityTests(unittest.TestCase):
    def test_current_version_and_build_are_bound_to_source_freeze(self) -> None:
        result = run(
            IDENTITY,
            "--repository-root",
            str(ROOT),
            "--version",
            "1.0.0",
            "--build",
            "2026071403",
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_different_version_or_build_is_rejected(self) -> None:
        for version, build in (("1.0.1", "2026071403"), ("1.0.0", "2026071501")):
            with self.subTest(version=version, build=build):
                result = run(
                    IDENTITY,
                    "--repository-root",
                    str(ROOT),
                    "--version",
                    version,
                    "--build",
                    build,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("differs from requested", result.stderr)

    def test_release_entrypoints_reject_ambiguous_phase_flags(self) -> None:
        release = subprocess.run(
            (
                "/bin/bash",
                str(ROOT / "Release/scripts/release.sh"),
                "--stage-candidate",
                "--promote-candidate",
            ),
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        preflight = subprocess.run(
            (
                "/bin/bash",
                str(ROOT / "ReleaseCandidate/scripts/preflight.sh"),
                "--candidate-stage",
                "--promotion",
            ),
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(release.returncode, 0)
        self.assertNotEqual(preflight.returncode, 0)
        self.assertIn("specified only once", release.stderr)
        self.assertIn("specified only once", preflight.stderr)


class CandidateStageTreeTests(unittest.TestCase):
    def stage(self, directory: Path) -> Path:
        root = directory / "candidate-stage-1.0.0-rc.1-2026071403"
        (root / "build/Vela.xcarchive/Products/Applications/Vela.app/Contents/Frameworks/Sparkle.framework/Versions/A").mkdir(
            parents=True
        )
        (root / "export/Vela.app/Contents/Frameworks/Sparkle.framework/Versions/A").mkdir(
            parents=True
        )
        (root / "public").mkdir()
        (root / "private").mkdir()
        (root / "updates").mkdir()
        for framework in (
            root / "build/Vela.xcarchive/Products/Applications/Vela.app/Contents/Frameworks/Sparkle.framework",
            root / "export/Vela.app/Contents/Frameworks/Sparkle.framework",
        ):
            (framework / "Versions/A/Sparkle").write_bytes(b"signed framework bytes")
            (framework / "Versions/Current").symlink_to("A")
            (framework / "Sparkle").symlink_to("Versions/Current/Sparkle")
        for current, directories, files in os.walk(root):
            Path(current).chmod(0o700)
            for name in files:
                path = Path(current) / name
                if not path.is_symlink():
                    path.chmod(0o600)
        return root

    def test_contained_framework_symlinks_are_allowed(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            result = run(TREE, str(self.stage(Path(raw))))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("contained bundle symlinks", result.stdout)

    def test_symlink_outside_bundle_or_stage_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = self.stage(Path(raw))
            (root / "private/unsafe").symlink_to("/tmp")
            result = run(TREE, str(root))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("outside an allowed bundle", result.stderr)

        with tempfile.TemporaryDirectory() as raw:
            root = self.stage(Path(raw))
            link = root / "export/Vela.app/Contents/Frameworks/Sparkle.framework/Versions/Current"
            link.unlink()
            link.symlink_to("../../../../../../../../../../tmp")
            result = run(TREE, str(root))
            self.assertNotEqual(result.returncode, 0)
            self.assertRegex(result.stderr, "dangling|escapes")


if __name__ == "__main__":
    unittest.main()
