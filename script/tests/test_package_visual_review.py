from __future__ import annotations

import importlib.util
import json
import struct
import subprocess
import sys
import tempfile
import unittest
import uuid
import zipfile
import zlib
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPOSITORY_ROOT / "script/package_visual_review.py"
SPEC = importlib.util.spec_from_file_location("package_visual_review", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
packager = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = packager
SPEC.loader.exec_module(packager)


def png_bytes(width: int, height: int, rgb: tuple[int, int, int]) -> bytes:
    signature = b"\x89PNG\r\n\x1a\n"

    def chunk(kind: bytes, payload: bytes) -> bytes:
        return (
            struct.pack(">I", len(payload))
            + kind
            + payload
            + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
        )

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    row = b"\x00" + bytes(rgb) * width
    pixels = zlib.compress(row * height, level=9)
    return signature + chunk(b"IHDR", ihdr) + chunk(b"IDAT", pixels) + chunk(b"IEND", b"")


def break_idat_zlib_with_valid_crc(value: bytes) -> bytes:
    changed = bytearray(value)
    offset = 8
    while offset < len(changed):
        length = struct.unpack(">I", changed[offset : offset + 4])[0]
        kind_start = offset + 4
        payload_start = kind_start + 4
        payload_end = payload_start + length
        checksum_start = payload_end
        kind = bytes(changed[kind_start:payload_start])
        if kind == b"IDAT":
            changed[payload_start] = 0
            payload = bytes(changed[payload_start:payload_end])
            checksum = zlib.crc32(kind + payload) & 0xFFFFFFFF
            changed[checksum_start : checksum_start + 4] = struct.pack(">I", checksum)
            return bytes(changed)
        offset = checksum_start + 4
    raise AssertionError("synthetic PNG has no IDAT chunk")


def rewrite_ihdr_dimensions(value: bytes, width: int, height: int) -> bytes:
    changed = bytearray(value)
    self_declared_length = struct.unpack(">I", changed[8:12])[0]
    if changed[12:16] != b"IHDR" or self_declared_length != 13:
        raise AssertionError("synthetic PNG has no leading IHDR")
    changed[16:24] = struct.pack(">II", width, height)
    payload = bytes(changed[16:29])
    changed[29:33] = struct.pack(">I", zlib.crc32(b"IHDR" + payload) & 0xFFFFFFFF)
    return bytes(changed)


class FakeAttachmentExporter:
    def __init__(self, attachment_sets: list[list[dict[str, object]]]) -> None:
        self.attachment_sets = attachment_sets
        self.calls = 0

    def __call__(self, _xcresult: Path, output: Path) -> None:
        attachments = self.attachment_sets[min(self.calls, len(self.attachment_sets) - 1)]
        self.calls += 1
        output.mkdir()
        manifest_attachments = []
        for attachment in attachments:
            exported_name = str(attachment["exportedFileName"])
            payload = attachment["payload"]
            assert isinstance(payload, bytes)
            if "/" not in exported_name and "\\" not in exported_name:
                (output / exported_name).write_bytes(payload)
            manifest_attachments.append(
                {
                    "exportedFileName": exported_name,
                    "suggestedHumanReadableName": attachment[
                        "suggestedHumanReadableName"
                    ],
                    "isAssociatedWithFailure": attachment.get(
                        "isAssociatedWithFailure", False
                    ),
                }
            )
        (output / "manifest.json").write_text(
            json.dumps(
                [
                    {
                        "testIdentifier": "VelaVisualSystemUITests/testSynthetic()",
                        "attachments": manifest_attachments,
                    }
                ]
            ),
            encoding="utf-8",
        )


def exported_screenshot(
    canonical_name: str,
    payload: bytes,
    *,
    token: str | None = None,
    failure: bool = False,
) -> dict[str, object]:
    unique = token or str(uuid.uuid4()).upper()
    stem = canonical_name.removesuffix(".png")
    return {
        "exportedFileName": f"{unique}.png",
        "suggestedHumanReadableName": f"{stem}_0_{unique}.png",
        "isAssociatedWithFailure": failure,
        "payload": payload,
    }


def synthetic_summary(
    *,
    result: str = "Passed",
    passed: int = 8,
    failed: int = 0,
    skipped: int = 0,
) -> dict[str, object]:
    return {
        "title": "Test - Vela",
        "environmentDescription": "Vela synthetic test environment",
        "result": result,
        "startTime": 1_784_053_664.668,
        "finishTime": 1_784_053_827.356,
        "totalTestCount": passed + failed + skipped,
        "passedTests": passed,
        "failedTests": failed,
        "skippedTests": skipped,
        "expectedFailures": 0,
    }


class VisualReviewPackagerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.xcresult = self.root / "Visual.xcresult"
        self.xcresult.mkdir()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def package(
        self,
        output: Path,
        exporter: FakeAttachmentExporter,
        *,
        summary: dict[str, object] | None = None,
    ) -> Path:
        summary_value = summary if summary is not None else synthetic_summary()
        return packager.package_visual_review(
            self.xcresult,
            output,
            "fixture-build",
            exporter=exporter,
            summary_reader=lambda _xcresult: summary_value,
        )

    def test_partial_pack_is_truthful_and_zip_is_reproducible(self) -> None:
        overview = png_bytes(1100, 720, (16, 32, 64))
        menu = png_bytes(236, 353, (80, 90, 100))
        unclassified = png_bytes(2, 2, (1, 2, 3))
        first = [
            exported_screenshot(
                "overview__offline__light__en__1100x720__na.png",
                overview,
                token="11111111-1111-1111-1111-111111111111",
            ),
            exported_screenshot(
                "menuBar__loaded__dark__zh-Hans__236x353__na.png",
                menu,
                token="22222222-2222-2222-2222-222222222222",
                failure=True,
            ),
            {
                "exportedFileName": "33333333-3333-3333-3333-333333333333.png",
                "suggestedHumanReadableName": "Automatic failure screenshot.png",
                "isAssociatedWithFailure": True,
                "payload": unclassified,
            },
            {
                "exportedFileName": "44444444-4444-4444-4444-444444444444.txt",
                "suggestedHumanReadableName": "menuBar__loaded__ax-diagnostic.txt",
                "payload": b"diagnostic\n",
            },
        ]
        second = [
            exported_screenshot(
                "overview__offline__light__en__1100x720__na.png",
                overview,
                token="AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            ),
            exported_screenshot(
                "menuBar__loaded__dark__zh-Hans__236x353__na.png",
                menu,
                token="BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                failure=True,
            ),
            {
                "exportedFileName": "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC.png",
                "suggestedHumanReadableName": "Automatic failure screenshot.png",
                "isAssociatedWithFailure": True,
                "payload": unclassified,
            },
            {
                "exportedFileName": "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD.txt",
                "suggestedHumanReadableName": "menuBar__loaded__ax-diagnostic.txt",
                "payload": b"diagnostic\n",
            },
        ]
        exporter = FakeAttachmentExporter([first, second])
        first_output = self.root / "review-one"
        second_output = self.root / "review-two"

        failed_summary = synthetic_summary(result="Failed", passed=7, failed=1)
        first_archive = self.package(
            first_output,
            exporter,
            summary=failed_summary,
        )
        second_archive = self.package(
            second_output,
            exporter,
            summary=failed_summary,
        )

        manifest = json.loads(
            (first_output / "screenshot-manifest.json").read_text(encoding="utf-8")
        )
        self.assertEqual(manifest["appBuild"], "caller-supplied:fixture-build")
        self.assertEqual(len(manifest["screenshots"]), 2)
        self.assertTrue(
            (
                first_output
                / "pages/overview/offline/light/en/"
                "overview__offline__light__en__1100x720__na.png"
            ).is_file()
        )
        coverage = json.loads(
            (first_output / "coverage.json").read_text(encoding="utf-8")
        )
        scenarios = coverage["visualScenarioCoverage"]
        fixtures = coverage["fixtureRouteCoverage"]
        accounting = coverage["attachmentAccounting"]
        provenance = coverage["provenance"]
        self.assertEqual(scenarios["expectedScenarioCount"], 1960)
        self.assertEqual(scenarios["capturedExpectedScenarioCount"], 2)
        self.assertEqual(scenarios["missingExpectedScenarioCount"], 1958)
        self.assertFalse(scenarios["complete"])
        self.assertEqual(fixtures["registeredFixtureCount"], 103)
        self.assertEqual(fixtures["registeredPageCount"], 13)
        self.assertEqual(fixtures["dedicatedVisualRouteCount"], 103)
        self.assertEqual(fixtures["routedPageCount"], 13)
        self.assertEqual(fixtures["unroutedRegisteredFixtureCount"], 0)
        self.assertEqual(fixtures["unroutedPageCount"], 0)
        self.assertEqual(fixtures["unroutedPages"], [])
        self.assertEqual(fixtures["capturedDedicatedVisualRouteCount"], 2)
        self.assertEqual(fixtures["capturedPageCount"], 2)
        self.assertEqual(fixtures["capturedPages"], ["menuBar", "overview"])
        self.assertEqual(fixtures["observedDedicatedVisualRouteCount"], 2)
        self.assertFalse(fixtures["fullFixtureRegistryCoverage"])
        self.assertEqual(accounting["unclassifiedPNGAttachmentCount"], 1)
        self.assertEqual(accounting["ignoredNonPNGAttachmentCount"], 1)
        self.assertEqual(provenance["testSummary"]["result"], "Failed")
        self.assertEqual(provenance["testSummary"]["totalTestCount"], 8)
        self.assertEqual(provenance["testSummary"]["passedTests"], 7)
        self.assertEqual(provenance["testSummary"]["failedTests"], 1)
        self.assertEqual(provenance["testSummary"]["skippedTests"], 0)
        self.assertEqual(provenance["testSummary"]["durationSeconds"], 162.688)
        self.assertEqual(provenance["buildLabelBinding"], "unverifiedCallerSupplied")
        self.assertEqual(
            provenance["evidenceClassification"], "historicalFailedOrPartial"
        )
        readme = (first_output / "README.md").read_text(encoding="utf-8")
        self.assertIn("registry-derived plan: 103", readme)
        self.assertIn("Registered Fixture Registry page/state IDs: 103", readme)
        self.assertIn("Full Fixture Registry coverage: no", readme)
        self.assertIn("full scenario coverage additionally requires", readme)
        self.assertIn("XCTest result: `Failed`", readme)
        self.assertIn("Tests: total 8; passed 7; failed 1; skipped 0", readme)
        self.assertIn("Caller-supplied build label, not bound", readme)
        self.assertIn("historical/partial evidence", readme)
        self.assertIn("do not describe", readme)
        self.assertIn("Registered pages: 13", readme)
        self.assertIn("Routed pages: 13", readme)
        self.assertIn(
            "Registered pages without a dedicated route: 0 (none)",
            readme,
        )
        self.assertNotIn("contains current screenshot evidence", readme)

        unclassified_manifest = json.loads(
            (first_output / "unclassified-manifest.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(unclassified_manifest["mediaType"], "image/png")
        self.assertEqual(len(unclassified_manifest["files"]), 1)
        unclassified_path = first_output / unclassified_manifest["files"][0]["path"]
        self.assertTrue(unclassified_path.name.endswith(".png.bin"))
        self.assertEqual(unclassified_path.read_bytes(), unclassified)

        registered_pngs = {item["path"] for item in manifest["screenshots"]}
        discovered_pngs = {
            path.relative_to(first_output).as_posix()
            for path in first_output.rglob("*.png")
        }
        self.assertEqual(discovered_pngs, registered_pngs)
        validator = (
            REPOSITORY_ROOT
            / "Docs/V1/Vela-Visual-Recovery-v2-Codex-Pack/scripts/"
            "validate_screenshot_manifest.py"
        )
        validation = subprocess.run(
            [
                sys.executable,
                str(validator),
                str(first_output / "screenshot-manifest.json"),
                "--root",
                str(first_output),
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            validation.returncode,
            0,
            validation.stdout + validation.stderr,
        )
        self.assertIn("Validated 2 screenshot(s).", validation.stdout)

        self.assertEqual(first_archive.read_bytes(), second_archive.read_bytes())
        with zipfile.ZipFile(first_archive) as bundle:
            names = bundle.namelist()
        self.assertIn("Vela-Visual-Review/README.md", names)
        self.assertNotIn("Vela-Visual-Review/Vela-Visual-Review.zip", names)
        self.assertFalse((first_output / ".xcresult-attachments").exists())

    def test_undersized_canonical_images_are_observed_but_not_captured(self) -> None:
        attachments = [
            exported_screenshot(
                "overview__offline__light__en__100x100__na.png",
                png_bytes(100, 100, (16, 32, 64)),
            ),
            exported_screenshot(
                "menuBar__loaded__dark__zh-Hans__4x3__na.png",
                png_bytes(4, 3, (80, 90, 100)),
            ),
        ]
        output = self.root / "undersized"

        self.package(output, FakeAttachmentExporter([attachments]))

        coverage = json.loads(
            (output / "coverage.json").read_text(encoding="utf-8")
        )
        scenarios = coverage["visualScenarioCoverage"]
        fixtures = coverage["fixtureRouteCoverage"]
        self.assertEqual(scenarios["capturedExpectedScenarioCount"], 0)
        self.assertEqual(scenarios["unexpectedScreenshotCount"], 2)
        self.assertEqual(
            {item["reason"] for item in scenarios["unexpectedScreenshots"]},
            {
                "unsupportedMainWindowPixelDimensions",
                "independentSurfaceBelowMinimumPixelDimensions",
            },
        )
        self.assertEqual(fixtures["capturedDedicatedVisualRouteCount"], 0)
        self.assertEqual(fixtures["capturedRegisteredFixtureCount"], 0)
        self.assertEqual(fixtures["capturedPageCount"], 0)
        self.assertEqual(fixtures["capturedPages"], [])
        self.assertEqual(fixtures["observedDedicatedVisualRouteCount"], 2)
        self.assertEqual(fixtures["observedRegisteredFixtureCount"], 2)
        self.assertEqual(fixtures["observedPageCount"], 2)

    def test_duplicate_contract_screenshot_fails_and_cleans_created_output(self) -> None:
        payload = png_bytes(1040, 680, (10, 20, 30))
        name = "overview__offline__light__en__1040x680__na.png"
        exporter = FakeAttachmentExporter(
            [[exported_screenshot(name, payload), exported_screenshot(name, payload)]]
        )
        output = self.root / "duplicate"

        with self.assertRaisesRegex(
            packager.ReviewPackError, "duplicate contract screenshot ID"
        ):
            self.package(output, exporter)

        self.assertFalse(output.exists())

    def test_dimension_mismatch_fails_closed(self) -> None:
        attachment = exported_screenshot(
            "overview__offline__light__en__1040x680__na.png",
            png_bytes(100, 100, (0, 0, 0)),
        )
        output = self.root / "dimension-mismatch"

        with self.assertRaisesRegex(packager.ReviewPackError, "do not match its name"):
            self.package(output, FakeAttachmentExporter([[attachment]]))

        self.assertFalse(output.exists())

    def test_corrupt_png_is_rejected_even_when_name_and_header_match(self) -> None:
        payload = bytearray(png_bytes(1040, 680, (0, 0, 0)))
        payload[-5] ^= 0xFF
        attachment = exported_screenshot(
            "overview__offline__light__en__1040x680__na.png",
            bytes(payload),
        )
        output = self.root / "corrupt"

        with self.assertRaisesRegex(packager.ReviewPackError, "checksum differs"):
            self.package(output, FakeAttachmentExporter([[attachment]]))

        self.assertFalse(output.exists())

    def test_crc_valid_but_broken_idat_stream_is_rejected(self) -> None:
        payload = break_idat_zlib_with_valid_crc(
            png_bytes(1040, 680, (12, 34, 56))
        )
        attachment = exported_screenshot(
            "overview__offline__light__en__1040x680__na.png",
            payload,
        )
        output = self.root / "broken-idat"

        with self.assertRaisesRegex(packager.ReviewPackError, "fully decoded safely"):
            self.package(output, FakeAttachmentExporter([[attachment]]))

        self.assertFalse(output.exists())

    def test_png_over_100_megapixels_is_rejected_before_decode(self) -> None:
        payload = rewrite_ihdr_dimensions(
            png_bytes(1, 1, (12, 34, 56)),
            10_001,
            10_000,
        )
        attachment = exported_screenshot(
            "overview__offline__light__en__10001x10000__na.png",
            payload,
        )
        output = self.root / "oversized"

        with self.assertRaisesRegex(packager.ReviewPackError, "pixel safety limit"):
            self.package(output, FakeAttachmentExporter([[attachment]]))

        self.assertFalse(output.exists())

    def test_exported_path_traversal_is_rejected(self) -> None:
        attachment = {
            "exportedFileName": "../outside.png",
            "suggestedHumanReadableName": (
                "overview__offline__light__en__1040x680__na.png"
            ),
            "payload": png_bytes(1040, 680, (0, 0, 0)),
        }
        output = self.root / "traversal"

        with self.assertRaisesRegex(packager.ReviewPackError, "unsafe exported"):
            self.package(output, FakeAttachmentExporter([[attachment]]))

        self.assertFalse(output.exists())
        self.assertFalse((self.root / "outside.png").exists())

    def test_existing_output_is_never_modified(self) -> None:
        output = self.root / "existing"
        output.mkdir()
        sentinel = output / "keep.txt"
        sentinel.write_text("keep\n", encoding="utf-8")

        with self.assertRaisesRegex(packager.ReviewPackError, "must not already exist"):
            self.package(output, FakeAttachmentExporter([[]]))

        self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep\n")

    def test_result_without_contract_screenshots_is_rejected(self) -> None:
        attachment = {
            "exportedFileName": "11111111-1111-1111-1111-111111111111.txt",
            "suggestedHumanReadableName": "diagnostic.txt",
            "payload": b"diagnostic\n",
        }
        output = self.root / "empty"

        with self.assertRaisesRegex(packager.ReviewPackError, "no contract-named"):
            self.package(output, FakeAttachmentExporter([[attachment]]))

        self.assertFalse(output.exists())

    def test_name_parser_accepts_xcresult_suffix_and_rejects_near_miss(self) -> None:
        parsed = packager.parse_suggested_screenshot_name(
            "tunFlow__permissionRequired__dark__zh-Hans__1560x1080__na_0_"
            "F0E0A139-4B92-4EA6-A810-3995BC4E1499.png"
        )
        self.assertIsNotNone(parsed)
        assert parsed is not None
        self.assertEqual(
            parsed.canonical_name,
            "tunFlow__permissionRequired__dark__zh-Hans__1560x1080__na.png",
        )
        self.assertIsNone(
            packager.parse_suggested_screenshot_name(
                "tunFlow__permissionRequired__sepia__zh-Hans__1560x1080__na.png"
            )
        )

    def test_summary_reader_uses_xcresulttool_and_normalizes_provenance(self) -> None:
        commands: list[list[str]] = []
        summary = synthetic_summary(result="Failed", passed=7, failed=1)

        def runner(command: list[str]) -> subprocess.CompletedProcess[str]:
            commands.append(command)
            return subprocess.CompletedProcess(
                command,
                0,
                stdout=json.dumps(summary),
                stderr="",
            )

        raw = packager.read_xcresult_summary(self.xcresult, runner=runner)
        normalized = packager.normalize_xcresult_summary(raw)

        self.assertEqual(
            commands,
            [[
                "/usr/bin/xcrun",
                "xcresulttool",
                "get",
                "test-results",
                "summary",
                "--path",
                str(self.xcresult),
            ]],
        )
        self.assertEqual(normalized["result"], "Failed")
        self.assertEqual(normalized["durationSeconds"], 162.688)

    def test_invalid_summary_fails_before_output_or_attachment_export(self) -> None:
        output = self.root / "bad-summary"
        exporter = FakeAttachmentExporter([[]])
        invalid = synthetic_summary()
        invalid["failedTests"] = 99

        with self.assertRaisesRegex(
            packager.ReviewPackError,
            "categorized test counts exceed totalTestCount",
        ):
            packager.package_visual_review(
                self.xcresult,
                output,
                "fixture-build",
                exporter=exporter,
                summary_reader=lambda _xcresult: invalid,
            )

        self.assertEqual(exporter.calls, 0)
        self.assertFalse(output.exists())

    def test_packager_matrix_contract_matches_fixture_registry(self) -> None:
        registry = json.loads(
            (REPOSITORY_ROOT / "VisualRecovery/Fixtures/fixture-registry.json")
            .read_text(encoding="utf-8")
        )
        registered = {fixture["id"] for fixture in registry["fixtures"]}
        routed = {route.fixture_id for route in packager.VISUAL_ROUTES}
        self.assertEqual(registered, routed)
        self.assertEqual(len(routed), 103)
        self.assertEqual(
            {route.page for route in packager.VISUAL_ROUTES},
            {
                "overview", "proxies", "connections", "rules",
                "providers", "workbench", "diagnostics", "logs",
                "settings", "tunFlow", "menuBar", "updateCoreRecovery",
                "helpSupport",
            },
        )
        connections = next(
            route for route in packager.VISUAL_ROUTES
            if route.fixture_id == "connections.loaded"
        )
        self.assertEqual(connections.inspectors, ("closed", "open"))
        diagnostics = next(
            route for route in packager.VISUAL_ROUTES
            if route.fixture_id == "diagnostics.loaded"
        )
        logs = next(
            route for route in packager.VISUAL_ROUTES
            if route.fixture_id == "logs.loaded"
        )
        self.assertEqual(diagnostics.inspectors, ("closed", "open"))
        self.assertEqual(logs.inspectors, ("closed", "open"))
        self.assertEqual(len(packager._expected_scenarios()), 1960)
        self.assertEqual(
            packager.load_fixture_defaults(),
            (registry["fixedDate"], str(registry["fixedUUIDSeed"])),
        )
        self.assertEqual(
            packager.INDEPENDENT_MINIMUM_PIXEL_DIMENSIONS,
            {
                "menuBar": (236, 353),
                "tunFlow": (780, 540),
            },
        )


if __name__ == "__main__":
    unittest.main()
