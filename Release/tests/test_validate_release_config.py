from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VALIDATOR = ROOT / "Release/scripts/validate_release_config.py"

SPEC = importlib.util.spec_from_file_location("validate_release_config", VALIDATOR)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class AppIntentReleaseGateTests(unittest.TestCase):
    def write_contract(self, root: Path, *, availability: str, marked_absent: bool) -> None:
        path = root / "Contracts/v1/public-contract-freeze.json"
        path.parent.mkdir(parents=True)
        value = {
            "absentSurfaces": ["productionAppIntents"] if marked_absent else [],
            "appIntents": {"availability": availability},
        }
        path.write_text(json.dumps(value) + "\n", encoding="utf-8")

    def test_current_release_requires_and_reports_absent_app_intents(self) -> None:
        config = json.loads(
            (ROOT / "Release/config/release.json").read_text(encoding="utf-8")
        )
        self.assertIs(config["releaseRequirements"]["requireAppIntents"], True)
        self.assertEqual(
            MODULE.app_intent_release_blockers(ROOT, required=True),
            ["App Intents are absent from the V1 public contract freeze"],
        )

        result = subprocess.run(
            [
                sys.executable,
                str(VALIDATOR),
                "--repository-root",
                str(ROOT),
                "--config",
                "Release/config/release.json",
                "--skip-toolchain",
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.count(
                "BLOCKER: App Intents are absent from the V1 public contract freeze"
            ),
            1,
        )

    def test_available_app_intents_clear_the_release_blocker(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            self.write_contract(root, availability="available", marked_absent=False)
            self.assertEqual(
                MODULE.app_intent_release_blockers(root, required=True),
                [],
            )

    def test_absent_surface_marker_must_match_availability(self) -> None:
        for availability, marked_absent in (("absent", False), ("available", True)):
            with self.subTest(availability=availability, marked_absent=marked_absent):
                with tempfile.TemporaryDirectory() as raw:
                    root = Path(raw)
                    self.write_contract(
                        root,
                        availability=availability,
                        marked_absent=marked_absent,
                    )
                    with self.assertRaises(MODULE.ValidationError):
                        MODULE.app_intent_release_blockers(root, required=True)


if __name__ == "__main__":
    unittest.main()
