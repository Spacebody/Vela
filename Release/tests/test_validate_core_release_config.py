from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CORE_DIR = ROOT / "Release/Core"
VALIDATOR = CORE_DIR / "validate_core_release_config.py"

sys.path.insert(0, str(CORE_DIR))
try:
    SPEC = importlib.util.spec_from_file_location(
        "validate_core_release_config",
        VALIDATOR,
    )
    assert SPEC is not None and SPEC.loader is not None
    MODULE = importlib.util.module_from_spec(SPEC)
    SPEC.loader.exec_module(MODULE)
finally:
    sys.path.remove(str(CORE_DIR))


class CoreCompatibilityFloorTests(unittest.TestCase):
    def test_current_app_version_is_accepted_against_core_floor(self) -> None:
        current = json.loads(
            (ROOT / "Release/config/release.json").read_text(encoding="utf-8")
        )["versioning"]["marketingVersion"]
        self.assertEqual(current, "1.0.0")
        self.assertTrue(MODULE.app_meets_core_compatibility_floor(current, "0.6.0"))

        result = subprocess.run(
            [sys.executable, str(VALIDATOR), "--repository-root", str(ROOT)],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("main App release configuration is not yet 0.6.0", result.stdout)
        self.assertNotIn("below Core compatibility floor", result.stdout)

    def test_newer_patch_minor_and_major_versions_are_accepted(self) -> None:
        for version in ("0.6.0", "0.6.1", "0.7.0", "1.0.0", "2.0.0"):
            with self.subTest(version=version):
                self.assertTrue(
                    MODULE.app_meets_core_compatibility_floor(version, "0.6.0")
                )

    def test_version_below_floor_is_rejected(self) -> None:
        self.assertFalse(MODULE.app_meets_core_compatibility_floor("0.5.99", "0.6.0"))

    def test_malformed_versions_fail_closed(self) -> None:
        for value in (None, 1, "1.0", "01.0.0", "1.0.0-rc.1"):
            with self.subTest(value=value):
                with self.assertRaises(MODULE.CoreReleaseError):
                    MODULE.app_meets_core_compatibility_floor(value, "0.6.0")


if __name__ == "__main__":
    unittest.main()
