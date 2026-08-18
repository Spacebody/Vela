from __future__ import annotations

import plistlib
import sys
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT / "script"))
import capture_visual_review_direct as capture  # noqa: E402


class DirectVisualCaptureTests(unittest.TestCase):
    def test_plan_exhaustively_matches_registry_derived_scenarios(self) -> None:
        scenarios = capture.planned_scenarios()
        self.assertEqual(len(scenarios), 2124)
        self.assertEqual(len({scenario.expected_id for scenario in scenarios}), 2124)
        self.assertEqual(
            {scenario.expected_id for scenario in scenarios},
            set(capture._expected_scenarios()),
        )
        self.assertEqual(
            sum(scenario.capture_boundary == "mainWindow" for scenario in scenarios),
            2060,
        )
        self.assertEqual(
            sum(scenario.capture_boundary != "mainWindow" for scenario in scenarios),
            64,
        )
        self.assertEqual(
            len({scenario.fixture_id for scenario in scenarios}),
            120,
        )
        self.assertIn("helpSupport.loaded", {scenario.fixture_id for scenario in scenarios})
        self.assertIn(
            "updateCoreRecovery.rollbackFailed",
            {scenario.fixture_id for scenario in scenarios},
        )
        self.assertEqual(
            {
                scenario.inspector
                for scenario in scenarios
                if scenario.fixture_id == "connections.loaded"
            },
            {"closed", "open"},
        )

    def test_dedicated_bundle_is_validated_and_hashed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            app = self._make_app(
                Path(temporary), capture.EXPECTED_BUNDLE_IDENTIFIER
            )
            validated = capture.validate_app_bundle(app)
            self.assertEqual(
                validated.bundle_identifier,
                capture.EXPECTED_BUNDLE_IDENTIFIER,
            )
            self.assertRegex(validated.executable_sha256, r"^[0-9a-f]{64}$")
            self.assertTrue(validated.executable.is_file())

    def test_production_bundle_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            app = self._make_app(
                Path(temporary), capture.PRODUCTION_BUNDLE_IDENTIFIER
            )
            with self.assertRaisesRegex(
                capture.DirectCaptureError,
                "non-dedicated bundle",
            ):
                capture.validate_app_bundle(app)

    def test_symlinked_executable_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = self._make_app(root, capture.EXPECTED_BUNDLE_IDENTIFIER)
            executable = app / "Contents/MacOS/Vela"
            executable.unlink()
            target = root / "outside"
            target.write_bytes(b"not the bundled executable")
            target.chmod(0o755)
            executable.symlink_to(target)
            with self.assertRaisesRegex(capture.DirectCaptureError, "symlink"):
                capture.validate_app_bundle(app)

    def test_output_must_be_absolute_absent_and_have_existing_parent(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaisesRegex(capture.DirectCaptureError, "absolute"):
                capture.validate_output(Path("relative"))
            existing = root / "existing"
            existing.mkdir()
            with self.assertRaisesRegex(capture.DirectCaptureError, "must not already"):
                capture.validate_output(existing)
            expected = root / "new-output"
            self.assertEqual(
                capture.validate_output(expected),
                root.resolve(strict=True) / "new-output",
            )

    def test_review_boundary_is_derived_from_run_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            staging = Path(temporary)
            empty = capture.derive_review_boundary(staging)
            self.assertFalse(any(empty.values()))

            (staging / "xctest-result.json").write_text(
                '{"result":"Passed"}\n', encoding="utf-8"
            )
            (staging / "source-binding.json").write_text(
                '{"clean":true,"commitSHA":"' + "a" * 40
                + '","executableSHA256":"' + "b" * 64 + '"}\n',
                encoding="utf-8",
            )
            (staging / "diffs").mkdir()
            (staging / "diffs/report.json").write_text(
                '{"complete":true}\n', encoding="utf-8"
            )
            observed = capture.derive_review_boundary(
                staging,
                expected_commit="a" * 40,
                expected_executable_sha256="b" * 64,
                workspace_clean=True,
            )
            self.assertTrue(observed["xctestPassIncluded"])
            self.assertTrue(observed["sourceTreeCryptographicallyBound"])
            self.assertTrue(observed["visualDiffIncluded"])
            self.assertFalse(observed["humanApprovalIncluded"])
            dirty = capture.derive_review_boundary(
                staging,
                expected_commit="a" * 40,
                expected_executable_sha256="b" * 64,
                workspace_clean=False,
            )
            self.assertFalse(dirty["sourceTreeCryptographicallyBound"])

    @staticmethod
    def _make_app(root: Path, bundle_identifier: str) -> Path:
        app = root / "Vela.app"
        macos = app / "Contents/MacOS"
        macos.mkdir(parents=True)
        with (app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump(
                {
                    "CFBundleIdentifier": bundle_identifier,
                    "CFBundleExecutable": "Vela",
                },
                stream,
            )
        executable = macos / "Vela"
        executable.write_bytes(b"#!/bin/sh\nexit 0\n")
        executable.chmod(executable.stat().st_mode | 0o111)
        return app


if __name__ == "__main__":
    unittest.main()
