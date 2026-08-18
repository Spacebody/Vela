from __future__ import annotations

import importlib.util
import json
import re
import shutil
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
VALIDATOR_PATH = REPOSITORY_ROOT / "script/validate_visual_recovery_contracts.py"
SPEC = importlib.util.spec_from_file_location(
    "validate_visual_recovery_contracts",
    VALIDATOR_PATH,
)
assert SPEC is not None and SPEC.loader is not None
validator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validator)


class VisualRecoveryContractValidatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / "Vela"
        self._copy_repository_inputs()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_repository_contracts_are_exact(self) -> None:
        self.assertEqual(validator.validate_repository(self.root), [])

    def test_missing_fixture_and_debug_state_are_rejected(self) -> None:
        registry_path = self.root / "VisualRecovery/Fixtures/fixture-registry.json"
        registry = self._load(registry_path)
        registry["fixtures"] = [
            fixture
            for fixture in registry["fixtures"]
            if fixture["id"] != "overview.loading"
        ]
        self._write(registry_path, registry)

        catalog_path = self.root / "VelaVisualHarness/VisualFixtureRouteCatalog.swift"
        source = catalog_path.read_text(encoding="utf-8")
        changed_source, replacement_count = re.subn(
            r"(case\s+\.overview\s*:\s*\[)\.loading\s*,\s*",
            r"\1",
            source,
            count=1,
        )
        self.assertEqual(replacement_count, 1)
        catalog_path.write_text(changed_source, encoding="utf-8")

        failures = validator.validate_repository(self.root)
        rendered = "\n".join(failures)
        self.assertIn("fixture registry IDs: missing ['overview.loading']", rendered)
        self.assertIn("Debug typed page/state catalog[overview]: missing ['loading']", rendered)

    def test_target_page_drift_is_rejected(self) -> None:
        status_path = self.root / "VisualRecovery/Targets/target-status.json"
        status = self._load(status_path)
        status["pages"].remove("helpSupport")
        status["pages"].append("notAContractPage")
        self._write(status_path, status)

        failures = "\n".join(validator.validate_repository(self.root))
        self.assertIn("target-status pages: missing ['helpSupport']", failures)
        self.assertIn("target-status pages: unexpected ['notAContractPage']", failures)

    def test_unregistered_or_undeclared_baseline_axes_are_rejected(self) -> None:
        baseline_path = (
            self.root / "VisualRecovery/Targets/visual-baseline-manifest.json"
        )
        baseline = self._load(baseline_path)
        baseline["baselines"] = [
            {
                "targetID": "invalid.axes",
                "page": "overview",
                "state": "rollbackFailed",
                "appearance": "sepia",
                "locale": "fr",
                "width": 999,
                "height": 777,
                "inspector": "closed",
                "captureBoundary": "mainWindow",
                "sha256": "0" * 64,
            }
        ]
        self._write(baseline_path, baseline)

        failures = "\n".join(validator.validate_repository(self.root))
        self.assertIn("unregistered page/state 'overview.rollbackFailed'", failures)
        self.assertIn("undeclared appearance 'sepia'", failures)
        self.assertIn("undeclared locale 'fr'", failures)
        self.assertIn("undeclared mainWindow target dimensions (999, 777)", failures)

    def test_cropped_boundaries_accept_positive_manifest_dimensions(self) -> None:
        self._set_baselines(
            [
                self._baseline(
                    page="menuBar",
                    state="loaded",
                    capture_boundary="menu",
                    width=472,
                    height=706,
                ),
                self._baseline(
                    page="tunFlow",
                    state="permissionRequired",
                    capture_boundary="sheet",
                    width=1560,
                    height=1080,
                ),
            ]
        )

        self.assertEqual(validator.validate_repository(self.root), [])

    def test_main_window_accepts_declared_1x_and_2x_dimensions(self) -> None:
        self._set_baselines(
            [
                self._baseline(
                    page="overview",
                    state="loaded",
                    width=1280,
                    height=820,
                ),
                self._baseline(
                    page="overview",
                    state="offline",
                    width=2560,
                    height=1640,
                ),
            ]
        )

        self.assertEqual(validator.validate_repository(self.root), [])

    def test_invalid_sha_inspector_and_boundary_are_rejected(self) -> None:
        item = self._baseline(page="overview", state="loaded")
        item["sha256"] = "A" * 64
        item["inspector"] = "hidden"
        item["captureBoundary"] = "popover"
        self._set_baselines([item])

        failures = "\n".join(validator.validate_repository(self.root))
        self.assertIn(
            "sha256 must be exactly 64 lowercase hexadecimal characters",
            failures,
        )
        self.assertIn("invalid inspector 'hidden'", failures)
        self.assertIn("invalid captureBoundary 'popover'", failures)

    def test_cropped_boundaries_reject_incompatible_pages(self) -> None:
        self._set_baselines(
            [
                self._baseline(
                    page="settings",
                    state="loaded",
                    capture_boundary="menu",
                ),
                self._baseline(
                    page="menuBar",
                    state="loaded",
                    capture_boundary="sheet",
                ),
            ]
        )

        failures = "\n".join(validator.validate_repository(self.root))
        self.assertIn(
            "captureBoundary 'menu' is only valid for page 'menuBar', got 'settings'",
            failures,
        )
        self.assertIn(
            "captureBoundary 'sheet' is only valid for page 'tunFlow', got 'menuBar'",
            failures,
        )

    def test_main_window_requires_declared_1x_or_2x_dimensions(self) -> None:
        self._set_baselines(
            [
                self._baseline(
                    page="overview",
                    state="loaded",
                    width=1279,
                    height=819,
                )
            ]
        )

        failures = "\n".join(validator.validate_repository(self.root))
        self.assertIn(
            "undeclared mainWindow target dimensions (1279, 819)", failures
        )

    def test_cropped_boundaries_require_positive_dimensions(self) -> None:
        self._set_baselines(
            [
                self._baseline(
                    page="menuBar",
                    state="loaded",
                    capture_boundary="menu",
                    width=0,
                    height=607,
                )
            ]
        )

        failures = "\n".join(validator.validate_repository(self.root))
        self.assertIn(
            "target dimensions must be positive integers, got (0, 607)", failures
        )

    def _copy_repository_inputs(self) -> None:
        (self.root / "VisualRecovery").mkdir(parents=True)
        shutil.copytree(
            REPOSITORY_ROOT / "VisualRecovery/Contracts",
            self.root / "VisualRecovery/Contracts",
        )
        for relative in (
            "VisualRecovery/Fixtures/fixture-registry.json",
            "VisualRecovery/Targets/target-status.json",
            "VisualRecovery/Targets/visual-baseline-manifest.json",
            "Docs/Vela-Visual-Recovery-v2-Codex-Pack/design/window-matrix.json",
            "VelaVisualHarness/VisualUITestConfiguration.swift",
            "VelaVisualHarness/VisualFixtureRouteCatalog.swift",
        ):
            source = REPOSITORY_ROOT / relative
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)

    @staticmethod
    def _load(path: Path) -> dict:
        return json.loads(path.read_text(encoding="utf-8"))

    @staticmethod
    def _write(path: Path, value: dict) -> None:
        path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")

    def _set_baselines(self, baselines: list[dict]) -> None:
        path = self.root / "VisualRecovery/Targets/visual-baseline-manifest.json"
        manifest = self._load(path)
        manifest["baselines"] = baselines
        self._write(path, manifest)

    @staticmethod
    def _baseline(
        *,
        page: str,
        state: str,
        capture_boundary: str = "mainWindow",
        width: int = 1280,
        height: int = 820,
    ) -> dict:
        return {
            "targetID": f"{page}.{state}.{capture_boundary}",
            "page": page,
            "state": state,
            "appearance": "dark",
            "locale": "en",
            "width": width,
            "height": height,
            "inspector": "closed",
            "captureBoundary": capture_boundary,
            "sha256": "0" * 64,
            "targetPath": f"targets/{'approved'}/{page}/{state}.png",
            "authority": "proposed",
            "approval": {
                "status": "pending",
                "approvedBy": None,
                "approvedAt": None,
            },
        }


if __name__ == "__main__":
    unittest.main()
