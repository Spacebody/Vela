from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Optional, Tuple


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
EMBED_SCRIPT = REPOSITORY_ROOT / "Release/scripts/embed_v07_resources.py"
PRODUCTION_BUNDLE_IDENTIFIER = "dev.yilin.Vela"
VISUAL_BUNDLE_IDENTIFIER = "dev.yilin.Vela.VisualTests"
RESOURCE_RELATIVE_PATH = Path("Localization/terminology.json")
SOURCE_ENTRY = "$(SRCROOT)/Vela/Resources/Localization/terminology.json"
OUTPUT_ENTRY = (
    "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/"
    "Localization/terminology.json"
)


class EmbedV07VisualBundleAllowlistTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.repository = self.root / "repository"
        self.input_list = self.root / "inputs.xcfilelist"
        self.output_list = self.root / "outputs.xcfilelist"

        source = self.repository / "Vela/Resources" / RESOURCE_RELATIVE_PATH
        source.parent.mkdir(parents=True)
        source.write_text('{"fixture":true}\n', encoding="utf-8")
        self.input_list.write_text(SOURCE_ENTRY + "\n", encoding="utf-8")
        self.output_list.write_text(OUTPUT_ENTRY + "\n", encoding="utf-8")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_production_release_is_accepted(self) -> None:
        result, embedded = self._run(
            case_name="production-release",
            bundle_identifier=PRODUCTION_BUNDLE_IDENTIFIER,
            configuration="Release",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(embedded.read_text(encoding="utf-8"), '{"fixture":true}\n')

    def test_visual_debug_with_explicit_build_flag_is_accepted(self) -> None:
        result, embedded = self._run(
            case_name="visual-debug",
            bundle_identifier=VISUAL_BUNDLE_IDENTIFIER,
            configuration="Debug",
            visual_test_build="YES",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(embedded.read_text(encoding="utf-8"), '{"fixture":true}\n')

    def test_visual_debug_without_build_flag_is_rejected(self) -> None:
        result, _ = self._run(
            case_name="visual-debug-missing-flag",
            bundle_identifier=VISUAL_BUNDLE_IDENTIFIER,
            configuration="Debug",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("may only be embedded in the Vela App target", result.stderr)

    def test_visual_release_is_rejected_even_with_build_flag(self) -> None:
        result, _ = self._run(
            case_name="visual-release",
            bundle_identifier=VISUAL_BUNDLE_IDENTIFIER,
            configuration="Release",
            visual_test_build="YES",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("may only be embedded in the Vela App target", result.stderr)

    def test_other_debug_bundle_is_rejected_even_with_build_flag(self) -> None:
        result, _ = self._run(
            case_name="other-debug",
            bundle_identifier="dev.yilin.Vela.UntrustedTests",
            configuration="Debug",
            visual_test_build="YES",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("may only be embedded in the Vela App target", result.stderr)

    def test_non_vela_full_product_name_is_rejected(self) -> None:
        result, _ = self._run(
            case_name="wrong-full-product-name",
            bundle_identifier=PRODUCTION_BUNDLE_IDENTIFIER,
            configuration="Release",
            full_product_name="NotVela.app",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FULL_PRODUCT_NAME must be Vela.app", result.stderr)

    def _run(
        self,
        *,
        case_name: str,
        bundle_identifier: str,
        configuration: str,
        visual_test_build: Optional[str] = None,
        full_product_name: str = "Vela.app",
    ) -> Tuple[subprocess.CompletedProcess, Path]:
        case_root = self.root / case_name
        target_build_dir = case_root / "build"
        target_temp_dir = case_root / "temporary"
        target_build_dir.mkdir(parents=True)
        target_temp_dir.mkdir(parents=True)

        environment = os.environ.copy()
        for key in (
            "CONFIGURATION",
            "FULL_PRODUCT_NAME",
            "PRODUCT_BUNDLE_IDENTIFIER",
            "SRCROOT",
            "TARGET_BUILD_DIR",
            "TARGET_TEMP_DIR",
            "UNLOCALIZED_RESOURCES_FOLDER_PATH",
            "VELA_VISUAL_TEST_BUILD",
        ):
            environment.pop(key, None)
        environment.update(
            {
                "CONFIGURATION": configuration,
                "FULL_PRODUCT_NAME": full_product_name,
                "PRODUCT_BUNDLE_IDENTIFIER": bundle_identifier,
                "SRCROOT": str(self.repository),
                "TARGET_BUILD_DIR": str(target_build_dir),
                "TARGET_TEMP_DIR": str(target_temp_dir),
                "UNLOCALIZED_RESOURCES_FOLDER_PATH": (
                    "Vela.app/Contents/Resources"
                ),
            }
        )
        if visual_test_build is not None:
            environment["VELA_VISUAL_TEST_BUILD"] = visual_test_build

        result = subprocess.run(
            [
                sys.executable,
                str(EMBED_SCRIPT),
                "--input-list",
                str(self.input_list),
                "--output-list",
                str(self.output_list),
            ],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        embedded = (
            target_build_dir
            / "Vela.app/Contents/Resources"
            / RESOURCE_RELATIVE_PATH
        )
        return result, embedded


if __name__ == "__main__":
    unittest.main()
