#!/usr/bin/env python3
"""Export deterministic Vela visual screenshots from one xcresult.

The command reads only the requested xcresult and checked-in fixture registry.
It refuses to merge into an existing output directory.  Every PNG attachment is
preserved: contract-named screenshots are organized under ``pages/`` while PNGs
without Vela's attachment metadata are retained byte-for-byte as ``.png.bin``
files under ``unclassified/`` and do not count as page or fixture coverage.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import shutil
import stat
import struct
import subprocess
import sys
import warnings
import zipfile
import zlib
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Iterable

from PIL import Image, UnidentifiedImageError


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
FIXTURE_REGISTRY = REPOSITORY_ROOT / "VisualRecovery/Fixtures/fixture-registry.json"
ARCHIVE_NAME = "Vela-Visual-Review.zip"
ARCHIVE_ROOT = "Vela-Visual-Review"

APPEARANCES = ("light", "dark")
LOCALES = ("en", "zh-Hans")
MAIN_WINDOW_SIZES = ((1040, 680), (1280, 820), (1600, 1000))
OVERVIEW_WINDOW_SIZES = ((1100, 720), (1280, 800), (1440, 900), (1600, 1000))


@dataclass(frozen=True)
class VisualRoute:
    page: str
    state: str
    fixture_identifier: str
    inspectors: tuple[str, ...]
    capture_boundary: str
    main_window: bool

    @property
    def fixture_id(self) -> str:
        return self.fixture_identifier


def main_window_sizes_for_route(
    route: VisualRoute,
) -> tuple[tuple[int, int], ...]:
    if route.page == "overview":
        return OVERVIEW_WINDOW_SIZES
    return MAIN_WINDOW_SIZES

MAIN_ROUTES: tuple[VisualRoute, ...]
INDEPENDENT_ROUTES: tuple[VisualRoute, ...]
VISUAL_ROUTES: tuple[VisualRoute, ...]
ROUTE_BY_AXES: dict[tuple[str, str, str], VisualRoute]

# Page-level surface capabilities are stable product structure. Page/state
# membership is intentionally not repeated here: it is loaded from the checked-
# in fixture registry below, so adding or removing a fixture changes the capture
# plan (or fails validation) instead of silently preserving a 13-route subset.
_PAGE_ROUTE_POLICIES = {
    "overview": ("mainWindow", True, ("na",)),
    "proxies": ("mainWindow", True, ("closed", "open")),
    "connections": ("mainWindow", True, ("closed", "open")),
    "rules": ("mainWindow", True, ("closed", "open")),
    "providers": ("mainWindow", True, ("closed", "open")),
    "workbench": ("mainWindow", True, ("closed", "open")),
    "diagnostics": ("mainWindow", True, ("closed", "open")),
    "logs": ("mainWindow", True, ("closed", "open")),
    # These two pages require VelaApp routing hooks, but they are full window
    # surfaces and therefore participate in the three-size matrix.
    "updateCoreRecovery": ("mainWindow", True, ("na",)),
    "helpSupport": ("mainWindow", True, ("na",)),
    "settings": ("mainWindow", True, ("na",)),
    "tunFlow": ("sheet", False, ("na",)),
    "menuBar": ("menu", False, ("na",)),
}
INDEPENDENT_MINIMUM_PIXEL_DIMENSIONS = {
    # Accept the established 1x logical boundary and its 2x capture. These are
    # minimums, not target dimensions: localized native surfaces may grow.
    "menuBar": (236, 353),
    "tunFlow": (780, 540),
}

SCREENSHOT_STEM_PATTERN = (
    r"(?P<page>[A-Za-z0-9-]+)__"
    r"(?P<state>[A-Za-z0-9-]+)__"
    r"(?P<appearance>light|dark)__"
    r"(?P<locale>en|zh-Hans)__"
    r"(?P<width>[1-9][0-9]*)x(?P<height>[1-9][0-9]*)__"
    r"(?P<inspector>open|closed|na)"
)
CANONICAL_SCREENSHOT_RE = re.compile(rf"^(?P<stem>{SCREENSHOT_STEM_PATTERN})\.png$")
EXPORTED_SCREENSHOT_RE = re.compile(
    rf"^(?P<stem>{SCREENSHOT_STEM_PATTERN})_"
    r"[0-9]+_"
    r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.png$"
)
SAFE_EXPORTED_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$")
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
MAX_PNG_CHUNK_BYTES = 256 * 1024 * 1024
MAX_PNG_PIXELS = 100_000_000
FIXED_ZIP_TIMESTAMP = (1980, 1, 1, 0, 0, 0)


class ReviewPackError(RuntimeError):
    pass


@dataclass(frozen=True)
class ScreenshotName:
    canonical_name: str
    page: str
    state: str
    appearance: str
    locale: str
    width: int
    height: int
    inspector: str

    @property
    def identifier(self) -> str:
        return self.canonical_name.removesuffix(".png")

    @property
    def fixture_id(self) -> str:
        route = ROUTE_BY_AXES.get((self.page, self.state, self.inspector))
        if route is not None:
            return route.fixture_id
        return f"{self.page}.{self.state}"


def _reject_nonfinite(value: str) -> None:
    raise ValueError(f"non-finite JSON number: {value}")


def parse_json_text(value: str, label: str) -> object:
    try:
        return json.loads(value, parse_constant=_reject_nonfinite)
    except (json.JSONDecodeError, ValueError) as error:
        raise ReviewPackError(f"invalid {label}: {error}") from error


def load_json(path: Path, label: str) -> object:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise ReviewPackError(f"invalid {label}: {error}") from error
    return parse_json_text(text, label)


def write_json(path: Path, value: object) -> None:
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    path.chmod(0o644)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def parse_suggested_screenshot_name(value: str) -> ScreenshotName | None:
    match = CANONICAL_SCREENSHOT_RE.fullmatch(value)
    if match is None:
        match = EXPORTED_SCREENSHOT_RE.fullmatch(value)
    if match is None:
        return None
    fields = match.groupdict()
    stem = fields["stem"]
    return ScreenshotName(
        canonical_name=f"{stem}.png",
        page=fields["page"],
        state=fields["state"],
        appearance=fields["appearance"],
        locale=fields["locale"],
        width=int(fields["width"]),
        height=int(fields["height"]),
        inspector=fields["inspector"],
    )


def png_dimensions(path: Path) -> tuple[int, int] | None:
    with path.open("rb") as stream:
        signature = stream.read(len(PNG_SIGNATURE))
        if signature != PNG_SIGNATURE:
            return None
        dimensions: tuple[int, int] | None = None
        saw_image_data = False
        chunk_index = 0
        while True:
            length_bytes = stream.read(4)
            if len(length_bytes) != 4:
                raise ReviewPackError(f"truncated PNG chunk length: {path.name}")
            length = struct.unpack(">I", length_bytes)[0]
            if length > MAX_PNG_CHUNK_BYTES:
                raise ReviewPackError(f"PNG chunk is unreasonably large: {path.name}")
            chunk_type = stream.read(4)
            if len(chunk_type) != 4:
                raise ReviewPackError(f"truncated PNG chunk type: {path.name}")
            payload = stream.read(length)
            checksum_bytes = stream.read(4)
            if len(payload) != length or len(checksum_bytes) != 4:
                raise ReviewPackError(f"truncated PNG chunk payload: {path.name}")
            expected_checksum = struct.unpack(">I", checksum_bytes)[0]
            actual_checksum = zlib.crc32(chunk_type + payload) & 0xFFFFFFFF
            if actual_checksum != expected_checksum:
                raise ReviewPackError(f"PNG chunk checksum differs: {path.name}")

            if chunk_index == 0:
                if chunk_type != b"IHDR" or length != 13:
                    raise ReviewPackError(f"PNG has no valid IHDR header: {path.name}")
                width, height = struct.unpack(">II", payload[:8])
                if width < 1 or height < 1:
                    raise ReviewPackError(f"PNG has invalid dimensions: {path.name}")
                dimensions = (width, height)
            elif chunk_type == b"IHDR":
                raise ReviewPackError(f"PNG contains multiple IHDR chunks: {path.name}")

            if chunk_type == b"IDAT":
                saw_image_data = True
            if chunk_type == b"IEND":
                if length != 0 or not saw_image_data or stream.read(1) != b"":
                    raise ReviewPackError(f"PNG has an invalid IEND boundary: {path.name}")
                if dimensions is None:
                    raise ReviewPackError(f"PNG dimensions are unavailable: {path.name}")
                return dimensions
            chunk_index += 1


def verify_png_decode(path: Path, ihdr_dimensions: tuple[int, int]) -> None:
    width, height = ihdr_dimensions
    if width * height > MAX_PNG_PIXELS:
        raise ReviewPackError(
            f"PNG exceeds the {MAX_PNG_PIXELS}-pixel safety limit: {path.name}"
        )

    previous_limit = Image.MAX_IMAGE_PIXELS
    Image.MAX_IMAGE_PIXELS = MAX_PNG_PIXELS
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(path) as image:
                if image.format != "PNG":
                    raise ReviewPackError(f"decoded image format is not PNG: {path.name}")
                if image.size != ihdr_dimensions:
                    raise ReviewPackError(
                        f"decoded PNG size {image.size} differs from IHDR "
                        f"{ihdr_dimensions}: {path.name}"
                    )
                image.verify()
            # Image.verify() deliberately invalidates the decoder. Reopen and
            # force pixel materialization so a CRC-valid but broken IDAT stream
            # cannot enter the evidence pack.
            with Image.open(path) as decoded:
                if decoded.format != "PNG" or decoded.size != ihdr_dimensions:
                    raise ReviewPackError(
                        f"reopened PNG metadata differs: {path.name}"
                    )
                decoded.load()
                if decoded.size != ihdr_dimensions:
                    raise ReviewPackError(
                        f"fully decoded PNG size differs: {path.name}"
                    )
    except ReviewPackError:
        raise
    except (
        Image.DecompressionBombError,
        Image.DecompressionBombWarning,
        UnidentifiedImageError,
        OSError,
        SyntaxError,
        ValueError,
    ) as error:
        raise ReviewPackError(
            f"PNG could not be fully decoded safely: {path.name}: {error}"
        ) from error
    finally:
        Image.MAX_IMAGE_PIXELS = previous_limit


def validate_app_build(value: str) -> str:
    if not value or len(value) > 256:
        raise ReviewPackError("--app-build must contain 1 to 256 characters")
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise ReviewPackError("--app-build cannot contain control characters")
    return value


def validate_input_xcresult(value: Path) -> Path:
    if not value.is_absolute():
        raise ReviewPackError("--xcresult must be an absolute path")
    if value.is_symlink():
        raise ReviewPackError("--xcresult cannot be a symlink")
    try:
        resolved = value.resolve(strict=True)
    except FileNotFoundError as error:
        raise ReviewPackError(f"xcresult does not exist: {value}") from error
    if resolved.suffix != ".xcresult" or not resolved.is_dir():
        raise ReviewPackError(f"xcresult must be a .xcresult directory: {resolved}")
    return resolved


def validate_output_root(value: Path, xcresult: Path) -> Path:
    if not value.is_absolute():
        raise ReviewPackError("--output-dir must be an absolute path")
    if value.name in {"", ".", ".."}:
        raise ReviewPackError("--output-dir must name a new directory")
    if value.exists() or value.is_symlink():
        raise ReviewPackError(f"output directory must not already exist: {value}")
    try:
        parent = value.parent.resolve(strict=True)
    except FileNotFoundError as error:
        raise ReviewPackError(f"output parent does not exist: {value.parent}") from error
    if not parent.is_dir():
        raise ReviewPackError(f"output parent is not a directory: {parent}")
    resolved = parent / value.name
    try:
        resolved.relative_to(xcresult)
    except ValueError:
        pass
    else:
        raise ReviewPackError("--output-dir cannot be inside the xcresult")
    return resolved


def load_fixture_records(path: Path = FIXTURE_REGISTRY) -> list[dict[str, object]]:
    if path.is_symlink() or not path.is_file():
        raise ReviewPackError(f"fixture registry is missing or unsafe: {path}")
    value = load_json(path, "fixture registry")
    if not isinstance(value, dict) or not isinstance(value.get("fixtures"), list):
        raise ReviewPackError("fixture registry must contain a fixtures array")
    records: list[dict[str, object]] = []
    for index, fixture in enumerate(value["fixtures"]):
        if not isinstance(fixture, dict):
            raise ReviewPackError(f"fixture registry entry {index} is not an object")
        fixture_id = fixture.get("id")
        page = fixture.get("page")
        state = fixture.get("state")
        if not all(isinstance(item, str) and item for item in (fixture_id, page, state)):
            raise ReviewPackError(
                f"fixture registry entry {index} requires string id/page/state"
            )
        if fixture.get("liveServicesAllowed") is not False:
            raise ReviewPackError(f"fixture {fixture_id} must deny live services")
        if fixture.get("sensitiveData") is not False:
            raise ReviewPackError(f"fixture {fixture_id} must not contain sensitive data")
        if fixture.get("dataSource") != "deterministicInMemory":
            raise ReviewPackError(
                f"fixture {fixture_id} must use deterministicInMemory data"
            )
        records.append(fixture)
    identifiers = [str(item["id"]) for item in records]
    if len(identifiers) != len(set(identifiers)):
        raise ReviewPackError("fixture registry contains duplicate fixture IDs")
    return records


def load_fixture_defaults(path: Path = FIXTURE_REGISTRY) -> tuple[str, str]:
    if path.is_symlink() or not path.is_file():
        raise ReviewPackError(f"fixture registry is missing or unsafe: {path}")
    value = load_json(path, "fixture registry")
    if not isinstance(value, dict):
        raise ReviewPackError("fixture registry must be an object")
    fixed_date = value.get("fixedDate")
    fixed_seed = value.get("fixedUUIDSeed")
    if not isinstance(fixed_date, str) or not fixed_date:
        raise ReviewPackError("fixture registry fixedDate must be a string")
    try:
        datetime.fromisoformat(fixed_date.replace("Z", "+00:00"))
    except ValueError as error:
        raise ReviewPackError("fixture registry fixedDate is not ISO-8601") from error
    if (
        not isinstance(fixed_seed, int)
        or isinstance(fixed_seed, bool)
        or fixed_seed < 0
        or fixed_seed > (1 << 64) - 1
    ):
        raise ReviewPackError("fixture registry fixedUUIDSeed must be UInt64")
    return fixed_date, str(fixed_seed)


def load_visual_routes(path: Path = FIXTURE_REGISTRY) -> tuple[VisualRoute, ...]:
    records = load_fixture_records(path)
    registered_pages = {str(item["page"]) for item in records}
    policy_pages = set(_PAGE_ROUTE_POLICIES)
    if registered_pages != policy_pages:
        missing = sorted(registered_pages - policy_pages)
        stale = sorted(policy_pages - registered_pages)
        raise ReviewPackError(
            "fixture route page policy differs from the registry: "
            f"missing={missing}, stale={stale}"
        )
    routes = []
    for fixture in records:
        page = str(fixture["page"])
        boundary, main_window, inspectors = _PAGE_ROUTE_POLICIES[page]
        routes.append(
            VisualRoute(
                page=page,
                state=str(fixture["state"]),
                fixture_identifier=str(fixture["id"]),
                inspectors=inspectors,
                capture_boundary=boundary,
                main_window=main_window,
            )
        )
    return tuple(routes)


VISUAL_ROUTES = load_visual_routes()
MAIN_ROUTES = tuple(route for route in VISUAL_ROUTES if route.main_window)
INDEPENDENT_ROUTES = tuple(route for route in VISUAL_ROUTES if not route.main_window)
ROUTE_BY_AXES = {
    (route.page, route.state, inspector): route
    for route in VISUAL_ROUTES
    for inspector in route.inspectors
}


def load_fixture_ids(path: Path = FIXTURE_REGISTRY) -> list[str]:
    identifiers = sorted(str(item["id"]) for item in load_fixture_records(path))
    route_ids = {route.fixture_id for route in VISUAL_ROUTES}
    registered_ids = set(identifiers)
    if route_ids != registered_ids:
        raise ReviewPackError(
            "visual routes differ from the fixture registry: "
            f"missing={sorted(registered_ids - route_ids)}, "
            f"unexpected={sorted(route_ids - registered_ids)}"
        )
    return identifiers


CommandRunner = Callable[[list[str]], subprocess.CompletedProcess[str]]


def run_command(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, capture_output=True, text=True)


def read_xcresult_summary(
    xcresult: Path,
    *,
    runner: CommandRunner = run_command,
) -> object:
    command = [
        "/usr/bin/xcrun",
        "xcresulttool",
        "get",
        "test-results",
        "summary",
        "--path",
        str(xcresult),
    ]
    completed = runner(command)
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise ReviewPackError(
            f"xcresult test summary failed ({completed.returncode}): {detail}"
        )
    return parse_json_text(completed.stdout, "xcresult test summary")


def _summary_count(value: dict[str, object], key: str) -> int:
    count = value.get(key)
    if isinstance(count, bool) or not isinstance(count, int) or count < 0:
        raise ReviewPackError(f"xcresult summary {key} must be a non-negative integer")
    return count


def _summary_time(value: dict[str, object], key: str) -> float | None:
    timestamp = value.get(key)
    if timestamp is None:
        return None
    if isinstance(timestamp, bool) or not isinstance(timestamp, (int, float)):
        raise ReviewPackError(f"xcresult summary {key} must be a finite number")
    result = float(timestamp)
    if not math.isfinite(result):
        raise ReviewPackError(f"xcresult summary {key} must be a finite number")
    return result


def normalize_xcresult_summary(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ReviewPackError("xcresult test summary must be an object")
    result = value.get("result")
    if not isinstance(result, str) or not result.strip() or len(result) > 128:
        raise ReviewPackError("xcresult summary result must be a non-empty string")

    counts = {
        key: _summary_count(value, key)
        for key in (
            "totalTestCount",
            "passedTests",
            "failedTests",
            "skippedTests",
            "expectedFailures",
        )
    }
    categorized = counts["passedTests"] + counts["failedTests"] + counts["skippedTests"]
    if categorized > counts["totalTestCount"]:
        raise ReviewPackError(
            "xcresult summary categorized test counts exceed totalTestCount"
        )

    start_time = _summary_time(value, "startTime")
    finish_time = _summary_time(value, "finishTime")
    duration: float | None = None
    if start_time is not None and finish_time is not None:
        if finish_time < start_time:
            raise ReviewPackError("xcresult summary finishTime precedes startTime")
        duration = round(finish_time - start_time, 6)

    normalized: dict[str, object] = {
        "result": result,
        "startTime": start_time,
        "finishTime": finish_time,
        "durationSeconds": duration,
        **counts,
    }
    for key in ("title", "environmentDescription"):
        item = value.get(key)
        if item is None:
            normalized[key] = None
        elif isinstance(item, str) and len(item) <= 1024 and not any(
            ord(character) < 32 and character not in "\t" for character in item
        ):
            normalized[key] = item
        else:
            raise ReviewPackError(f"xcresult summary {key} has invalid text")
    return normalized


def export_xcresult_attachments(xcresult: Path, output: Path) -> None:
    if output.exists() or output.is_symlink():
        raise ReviewPackError(f"attachment export path must be absent: {output}")
    command = [
        "/usr/bin/xcrun",
        "xcresulttool",
        "export",
        "attachments",
        "--path",
        str(xcresult),
        "--output-path",
        str(output),
    ]
    completed = subprocess.run(command, capture_output=True, text=True)
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise ReviewPackError(
            f"xcresult attachment export failed ({completed.returncode}): {detail}"
        )


def _validate_exported_name(value: object) -> str:
    if not isinstance(value, str) or not SAFE_EXPORTED_NAME_RE.fullmatch(value):
        raise ReviewPackError(f"unsafe exported attachment filename: {value!r}")
    if value in {".", "..", "manifest.json"}:
        raise ReviewPackError(f"reserved exported attachment filename: {value!r}")
    return value


def _regular_file(path: Path, label: str) -> Path:
    if path.is_symlink():
        raise ReviewPackError(f"{label} cannot be a symlink: {path}")
    try:
        mode = path.stat().st_mode
    except FileNotFoundError as error:
        raise ReviewPackError(f"{label} is missing: {path}") from error
    if not stat.S_ISREG(mode):
        raise ReviewPackError(f"{label} is not a regular file: {path}")
    return path


def read_export_manifest(export_root: Path) -> list[dict[str, object]]:
    if export_root.is_symlink() or not export_root.is_dir():
        raise ReviewPackError("xcresulttool did not create a safe attachment directory")
    for discovered in export_root.rglob("*"):
        if discovered.is_symlink():
            raise ReviewPackError(f"attachment export contains a symlink: {discovered}")
        mode = discovered.stat().st_mode
        if not stat.S_ISDIR(mode) and not stat.S_ISREG(mode):
            raise ReviewPackError(f"attachment export contains a special file: {discovered}")

    manifest_path = _regular_file(export_root / "manifest.json", "export manifest")
    value = load_json(manifest_path, "xcresult attachment manifest")
    if not isinstance(value, list):
        raise ReviewPackError("xcresult attachment manifest must be an array")

    attachments: list[dict[str, object]] = []
    referenced_names: set[str] = set()
    for group_index, group in enumerate(value):
        if not isinstance(group, dict):
            raise ReviewPackError(f"attachment group {group_index} is not an object")
        test_identifier = group.get("testIdentifier")
        group_attachments = group.get("attachments")
        if not isinstance(test_identifier, str) or not test_identifier:
            raise ReviewPackError(f"attachment group {group_index} has no testIdentifier")
        if not isinstance(group_attachments, list):
            raise ReviewPackError(f"attachment group {group_index} has no attachments array")
        for attachment_index, attachment in enumerate(group_attachments):
            if not isinstance(attachment, dict):
                raise ReviewPackError(
                    f"attachment {group_index}/{attachment_index} is not an object"
                )
            exported_name = _validate_exported_name(attachment.get("exportedFileName"))
            if exported_name in referenced_names:
                raise ReviewPackError(
                    f"export manifest references {exported_name!r} more than once"
                )
            referenced_names.add(exported_name)
            suggested_name = attachment.get("suggestedHumanReadableName")
            failure = attachment.get("isAssociatedWithFailure")
            if not isinstance(suggested_name, str) or not isinstance(failure, bool):
                raise ReviewPackError(
                    f"attachment {exported_name!r} has invalid metadata"
                )
            source = _regular_file(
                export_root / exported_name,
                f"exported attachment {exported_name!r}",
            )
            attachments.append(
                {
                    "testIdentifier": test_identifier,
                    "exportedFileName": exported_name,
                    "suggestedHumanReadableName": suggested_name,
                    "isAssociatedWithFailure": failure,
                    "source": source,
                }
            )

    discovered_names = {
        path.name
        for path in export_root.iterdir()
        if path.name != "manifest.json" and path.is_file()
    }
    unreferenced = sorted(discovered_names - referenced_names)
    missing = sorted(referenced_names - discovered_names)
    if unreferenced or missing:
        details = []
        if unreferenced:
            details.append(f"unreferenced exported files: {unreferenced}")
        if missing:
            details.append(f"manifest files not found: {missing}")
        raise ReviewPackError("; ".join(details))
    nested_files = [
        path for path in export_root.rglob("*")
        if path.is_file() and path.parent != export_root
    ]
    if nested_files:
        raise ReviewPackError("attachment export unexpectedly contains nested files")
    return attachments


def _copy_regular_file(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() or destination.is_symlink():
        raise ReviewPackError(f"refusing to overwrite packaged file: {destination}")
    shutil.copyfile(source, destination)
    destination.chmod(0o644)


def _expected_scenarios() -> dict[str, VisualRoute]:
    scenarios: dict[str, VisualRoute] = {}
    for route in MAIN_ROUTES:
        for inspector in route.inspectors:
            for locale in LOCALES:
                for appearance in APPEARANCES:
                    for width, height in main_window_sizes_for_route(route):
                        identifier = (
                            f"{route.page}__{route.state}__{appearance}__{locale}__"
                            f"window-{width}x{height}__{inspector}"
                        )
                        scenarios[identifier] = route
    for route in INDEPENDENT_ROUTES:
        for inspector in route.inspectors:
            for locale in LOCALES:
                for appearance in APPEARANCES:
                    identifier = (
                        f"{route.page}__{route.state}__{appearance}__{locale}__"
                        f"{route.capture_boundary}__{inspector}"
                    )
                    scenarios[identifier] = route
    return scenarios


def _match_expected_scenario(
    screenshot: ScreenshotName,
) -> tuple[str | None, str | None]:
    route = ROUTE_BY_AXES.get(
        (screenshot.page, screenshot.state, screenshot.inspector)
    )
    if route is None:
        return None, "notADedicatedVisualRoute"
    if route.main_window:
        matching_sizes = [
            (width, height)
            for width, height in main_window_sizes_for_route(route)
            if (screenshot.width, screenshot.height) in {
                (width, height),
                (width * 2, height * 2),
            }
        ]
        if len(matching_sizes) != 1:
            return None, "unsupportedMainWindowPixelDimensions"
        width, height = matching_sizes[0]
        return (
            f"{route.page}__{route.state}__{screenshot.appearance}__"
            f"{screenshot.locale}__window-{width}x{height}__{screenshot.inspector}",
            None,
        )
    minimum_width, minimum_height = INDEPENDENT_MINIMUM_PIXEL_DIMENSIONS[
        route.page
    ]
    if screenshot.width < minimum_width or screenshot.height < minimum_height:
        return None, "independentSurfaceBelowMinimumPixelDimensions"
    return (
        f"{route.page}__{route.state}__{screenshot.appearance}__"
        f"{screenshot.locale}__{route.capture_boundary}__{screenshot.inspector}",
        None,
    )


def _page_coverage(
    expected: dict[str, VisualRoute],
    matched: dict[str, list[str]],
    screenshots: list[dict[str, object]],
) -> list[dict[str, object]]:
    fixture_counts = Counter(
        (
            ROUTE_BY_AXES[
                (str(item["page"]), str(item["state"]), str(item["inspector"]))
            ].fixture_id
            if (
                str(item["page"]),
                str(item["state"]),
                str(item["inspector"]),
            ) in ROUTE_BY_AXES
            else f"{item['page']}.{item['state']}"
        )
        for item in screenshots
    )
    results = []
    for route in VISUAL_ROUTES:
        expected_ids = sorted(
            identifier
            for identifier, expected_route in expected.items()
            if expected_route.fixture_id == route.fixture_id
        )
        captured = [identifier for identifier in expected_ids if identifier in matched]
        results.append(
            {
                "fixtureID": route.fixture_id,
                "page": route.page,
                "state": route.state,
                "captureBoundary": route.capture_boundary,
                "expectedScenarioCount": len(expected_ids),
                "capturedExpectedScenarioCount": len(captured),
                "missingExpectedScenarioCount": len(expected_ids) - len(captured),
                "screenshotAttachmentCount": fixture_counts[route.fixture_id],
            }
        )
    return results


def build_artifacts(
    export_root: Path,
    output_root: Path,
    app_build: str,
    fixture_ids: list[str],
    test_summary: dict[str, object],
) -> None:
    attachments = read_export_manifest(export_root)
    screenshots: list[dict[str, object]] = []
    screenshot_names: dict[str, ScreenshotName] = {}
    screenshot_tests: dict[str, str] = {}
    screenshot_failures: dict[str, bool] = {}
    unclassified: dict[str, dict[str, object]] = {}
    non_png_kinds: Counter[str] = Counter()

    for attachment in attachments:
        source = attachment["source"]
        assert isinstance(source, Path)
        suggested_name = attachment["suggestedHumanReadableName"]
        assert isinstance(suggested_name, str)
        dimensions = png_dimensions(source)
        if dimensions is not None:
            verify_png_decode(source, dimensions)
        parsed = parse_suggested_screenshot_name(suggested_name)

        if parsed is not None:
            if dimensions is None:
                raise ReviewPackError(
                    f"contract screenshot is not a PNG: {suggested_name!r}"
                )
            if dimensions != (parsed.width, parsed.height):
                raise ReviewPackError(
                    f"{parsed.canonical_name}: attachment dimensions {dimensions} "
                    f"do not match its name {(parsed.width, parsed.height)}"
                )
            if parsed.identifier in screenshot_names:
                raise ReviewPackError(
                    f"duplicate contract screenshot ID: {parsed.identifier}"
                )
            destination = (
                output_root
                / "pages"
                / parsed.page
                / parsed.state
                / parsed.appearance
                / parsed.locale
                / parsed.canonical_name
            )
            _copy_regular_file(source, destination)
            relative = destination.relative_to(output_root).as_posix()
            item = {
                "id": parsed.identifier,
                "page": parsed.page,
                "state": parsed.state,
                "appearance": parsed.appearance,
                "locale": parsed.locale,
                "width": parsed.width,
                "height": parsed.height,
                "inspector": parsed.inspector,
                "path": relative,
                "sha256": sha256(destination),
            }
            screenshots.append(item)
            screenshot_names[parsed.identifier] = parsed
            screenshot_tests[parsed.identifier] = str(attachment["testIdentifier"])
            screenshot_failures[parsed.identifier] = bool(
                attachment["isAssociatedWithFailure"]
            )
            continue

        if dimensions is not None:
            digest = sha256(source)
            # Keep the exact PNG bytes for diagnostics, but do not expose the
            # file as a screenshot. The pack validator intentionally treats
            # every recursively discovered *.png as canonical evidence that
            # must be registered by screenshot-manifest.json.
            destination = output_root / "unclassified" / f"{digest}.png.bin"
            if digest not in unclassified:
                _copy_regular_file(source, destination)
                unclassified[digest] = {
                    "path": destination.relative_to(output_root).as_posix(),
                    "sha256": digest,
                    "width": dimensions[0],
                    "height": dimensions[1],
                    "attachmentCount": 0,
                    "associatedWithFailureCount": 0,
                }
            record = unclassified[digest]
            record["attachmentCount"] = int(record["attachmentCount"]) + 1
            if attachment["isAssociatedWithFailure"]:
                record["associatedWithFailureCount"] = int(
                    record["associatedWithFailureCount"]
                ) + 1
            continue

        exported_name = str(attachment["exportedFileName"])
        suffix = Path(exported_name).suffix.lower()
        if suffix == ".txt":
            non_png_kinds["text"] += 1
        elif suffix in {".mp4", ".mov"}:
            non_png_kinds["video"] += 1
        else:
            non_png_kinds["other"] += 1

    if not screenshots:
        raise ReviewPackError(
            "xcresult contains no contract-named Vela screenshot attachments"
        )

    unclassified_files = sorted(
        unclassified.values(), key=lambda item: str(item["sha256"])
    )
    write_json(
        output_root / "unclassified-manifest.json",
        {
            "schemaVersion": 1,
            "mediaType": "image/png",
            "files": unclassified_files,
        },
    )

    screenshots.sort(key=lambda item: str(item["id"]))
    screenshot_manifest = {
        "schemaVersion": 1,
        # The screenshot-manifest schema has no provenance object. Keep its
        # required string field compatible while making the lack of binding
        # explicit instead of presenting caller text as an observed build ID.
        "appBuild": f"caller-supplied:{app_build}",
        "screenshots": screenshots,
    }
    write_json(output_root / "screenshot-manifest.json", screenshot_manifest)

    expected = _expected_scenarios()
    matched: dict[str, list[str]] = defaultdict(list)
    unexpected = []
    for item in screenshots:
        identifier = str(item["id"])
        scenario, reason = _match_expected_scenario(screenshot_names[identifier])
        if scenario is None:
            unexpected.append({"screenshotID": identifier, "reason": reason})
        else:
            matched[scenario].append(identifier)

    duplicates = [
        {"scenarioID": scenario, "screenshotIDs": sorted(identifiers)}
        for scenario, identifiers in sorted(matched.items())
        if len(identifiers) > 1
    ]
    missing = sorted(set(expected) - set(matched))
    captured_expected = len(expected) - len(missing)

    fixture_id_set = set(fixture_ids)
    dedicated_ids = {route.fixture_id for route in VISUAL_ROUTES}
    routed_pages = {route.page for route in VISUAL_ROUTES}
    registered_pages = {
        identifier.split(".", 1)[0] for identifier in fixture_ids
    }
    matched_screenshot_ids = {
        identifier
        for identifiers in matched.values()
        for identifier in identifiers
    }
    observed_registered_ids = sorted(
        {
            screenshot_names[str(item["id"])].fixture_id
            for item in screenshots
            if screenshot_names[str(item["id"])].fixture_id in fixture_id_set
        }
    )
    observed_dedicated_ids = sorted(set(observed_registered_ids) & dedicated_ids)
    observed_pages = sorted(
        {
            screenshot_names[str(item["id"])].page
            for item in screenshots
            if screenshot_names[str(item["id"])].page in registered_pages
        }
    )
    captured_registered_ids = sorted(
        {
            screenshot_names[identifier].fixture_id
            for identifier in matched_screenshot_ids
            if screenshot_names[identifier].fixture_id in fixture_id_set
        }
    )
    captured_dedicated_ids = sorted(set(captured_registered_ids) & dedicated_ids)
    captured_pages = sorted(
        {
            screenshot_names[identifier].page
            for identifier in matched_screenshot_ids
            if screenshot_names[identifier].page in routed_pages
        }
    )
    full_fixture_coverage = set(captured_registered_ids) == fixture_id_set

    visual_scenario_complete = (
        not missing
        and not unexpected
        and not duplicates
        and len(screenshots) == len(expected)
    )
    result_passed = str(test_summary["result"]).casefold() in {
        "passed",
        "succeeded",
        "success",
    }
    evidence_classification = (
        "completeResultEvidence"
        if result_passed and visual_scenario_complete
        else "historicalFailedOrPartial"
    )
    packaged_paths = {
        path.relative_to(output_root).as_posix()
        for path in output_root.rglob("*")
        if path.is_file() and not path.is_symlink()
    }

    def has_packaged_prefix(prefix: str) -> bool:
        return any(
            path == prefix or path.startswith(prefix + "/")
            for path in packaged_paths
        )

    review_boundary: dict[str, object] = {
        "approvedPixelTargetsIncluded": has_packaged_prefix("approved-targets"),
        "visualDiffIncluded": has_packaged_prefix("diffs"),
        "humanApprovalIncluded": "human-approval.json" in packaged_paths,
        "xctestPassIncluded": result_passed,
        "xctestResultSource": "xcresulttool get test-results summary",
        "sourceTreeCryptographicallyBound": "source-binding.json" in packaged_paths,
    }
    coverage = {
        "schemaVersion": 1,
        "coverageClaim": "visualScenarioEvidenceOnly",
        "provenance": {
            "summarySource": "xcresulttool get test-results summary",
            "testSummary": test_summary,
            "callerSuppliedBuildLabel": app_build,
            "buildLabelBinding": "unverifiedCallerSupplied",
            "evidenceClassification": evidence_classification,
            "captureRecencyEstablished": False,
        },
        "visualScenarioCoverage": {
            "expectedScenarioCount": len(expected),
            "capturedExpectedScenarioCount": captured_expected,
            "missingExpectedScenarioCount": len(missing),
            "unexpectedScreenshotCount": len(unexpected),
            "duplicateExpectedScenarioCount": len(duplicates),
            "complete": visual_scenario_complete,
            "missingExpectedScenarios": missing,
            "unexpectedScreenshots": unexpected,
            "duplicateExpectedScenarios": duplicates,
            "pages": _page_coverage(expected, matched, screenshots),
        },
        "fixtureRouteCoverage": {
            "registeredFixtureCount": len(fixture_ids),
            "registeredPageCount": len(registered_pages),
            "dedicatedVisualRouteCount": len(dedicated_ids),
            "routedPageCount": len(routed_pages),
            "unroutedRegisteredFixtureCount": len(fixture_id_set - dedicated_ids),
            "unroutedPageCount": len(registered_pages - routed_pages),
            "unroutedPages": sorted(registered_pages - routed_pages),
            "capturedDedicatedVisualRouteCount": len(captured_dedicated_ids),
            "capturedRegisteredFixtureCount": len(captured_registered_ids),
            "capturedPageCount": len(captured_pages),
            "capturedPages": captured_pages,
            "observedDedicatedVisualRouteCount": len(observed_dedicated_ids),
            "observedDedicatedVisualRouteIDs": observed_dedicated_ids,
            "observedRegisteredFixtureCount": len(observed_registered_ids),
            "observedRegisteredFixtureIDs": observed_registered_ids,
            "observedPageCount": len(observed_pages),
            "observedPages": observed_pages,
            "fullFixtureRegistryCoverage": full_fixture_coverage,
            "dedicatedVisualRouteIDs": sorted(dedicated_ids),
            "capturedDedicatedVisualRouteIDs": captured_dedicated_ids,
            "capturedRegisteredFixtureIDs": captured_registered_ids,
            "unroutedRegisteredFixtureIDs": sorted(fixture_id_set - dedicated_ids),
        },
        "attachmentAccounting": {
            "totalAttachmentCount": len(attachments),
            "contractScreenshotAttachmentCount": len(screenshots),
            "contractScreenshotsAssociatedWithFailureCount": sum(
                screenshot_failures.values()
            ),
            "unclassifiedPNGAttachmentCount": sum(
                int(item["attachmentCount"]) for item in unclassified.values()
            ),
            "unclassifiedUniquePNGCount": len(unclassified),
            "ignoredNonPNGAttachmentCount": sum(non_png_kinds.values()),
            "ignoredNonPNGByKind": dict(sorted(non_png_kinds.items())),
            "unclassifiedPNGs": unclassified_files,
        },
        "screenshotSources": [
            {
                "screenshotID": identifier,
                "testIdentifier": screenshot_tests[identifier],
                "isAssociatedWithFailure": screenshot_failures[identifier],
            }
            for identifier in sorted(screenshot_tests)
        ],
        "reviewBoundary": review_boundary,
    }
    write_json(output_root / "coverage.json", coverage)
    (output_root / "README.md").write_text(
        render_readme(app_build, coverage),
        encoding="utf-8",
    )
    (output_root / "README.md").chmod(0o644)


def _markdown_code(value: str) -> str:
    return "`" + value.replace("`", "\\`") + "`"


def _summary_timestamp(value: object) -> str:
    if value is None:
        return "unavailable"
    try:
        timestamp = float(value)
        rendered = datetime.fromtimestamp(timestamp, timezone.utc).isoformat(
            timespec="milliseconds"
        ).replace("+00:00", "Z")
    except (OverflowError, OSError, TypeError, ValueError):
        return f"unix:{value}"
    return f"{rendered} (unix:{timestamp:.3f})"


def render_readme(app_build: str, coverage: dict[str, object]) -> str:
    scenarios = coverage["visualScenarioCoverage"]
    fixtures = coverage["fixtureRouteCoverage"]
    attachments = coverage["attachmentAccounting"]
    provenance = coverage["provenance"]
    assert isinstance(scenarios, dict)
    assert isinstance(fixtures, dict)
    assert isinstance(attachments, dict)
    assert isinstance(provenance, dict)
    test_summary = provenance["testSummary"]
    assert isinstance(test_summary, dict)
    complete = "yes" if scenarios["complete"] else "no"
    unrouted_pages = ", ".join(fixtures["unroutedPages"]) or "none"
    lines = [
        "# Vela Visual Review Pack",
        "",
        "This archive contains screenshot evidence exported from one xcresult.",
        "It is not an approved pixel target set, a visual diff result, or a human approval.",
        "",
        "## Result provenance",
        "",
        f"- XCTest result: {_markdown_code(str(test_summary['result']))}",
        f"- Start: {_summary_timestamp(test_summary['startTime'])}",
        f"- Finish: {_summary_timestamp(test_summary['finishTime'])}",
        f"- Duration: {test_summary['durationSeconds'] if test_summary['durationSeconds'] is not None else 'unavailable'} seconds",
        f"- Tests: total {test_summary['totalTestCount']}; passed {test_summary['passedTests']}; failed {test_summary['failedTests']}; skipped {test_summary['skippedTests']}; expected failures {test_summary['expectedFailures']}",
        f"- Caller-supplied build label, not bound to the xcresult: {_markdown_code(app_build)}",
        f"- Build-label binding: {_markdown_code(str(provenance['buildLabelBinding']))}",
        f"- Evidence classification: {_markdown_code(str(provenance['evidenceClassification']))}",
        "- Capture recency/currentness: not established by this package.",
        "",
    ]
    if provenance["evidenceClassification"] == "historicalFailedOrPartial":
        lines.extend(
            [
                "> This xcresult failed and/or its expected visual matrix is partial. Treat",
                "> these screenshots only as historical/partial evidence; do not describe",
                "> them as current or complete.",
                "",
            ]
        )
    lines.extend(
        [
            "## Capture summary",
            "",
            f"- Contract screenshot attachments: {attachments['contractScreenshotAttachmentCount']}",
            f"- Expected visual scenarios represented: {scenarios['capturedExpectedScenarioCount']}/{scenarios['expectedScenarioCount']}",
            f"- Complete {scenarios['expectedScenarioCount']}-scenario visual matrix: {complete}",
            f"- Unexpected contract screenshots: {scenarios['unexpectedScreenshotCount']}",
            f"- Duplicate expected scenarios: {scenarios['duplicateExpectedScenarioCount']}",
            f"- Contract screenshots associated with a failure: {attachments['contractScreenshotsAssociatedWithFailureCount']}",
            "- Overall XCTest result: reported by xcresulttool, never inferred from attachment counts.",
            "",
            "## Fixture coverage boundary",
            "",
            f"- Registered Fixture Registry page/state IDs: {fixtures['registeredFixtureCount']}",
            f"- Registered pages: {fixtures['registeredPageCount']}",
            f"- Dedicated visual capture routes declared by the registry-derived plan: {fixtures['dedicatedVisualRouteCount']}",
            f"- Routed pages: {fixtures['routedPageCount']}",
            f"- Dedicated routes captured in this result: {fixtures['capturedDedicatedVisualRouteCount']}/{fixtures['dedicatedVisualRouteCount']}",
            f"- Pages captured through a successfully matched expected scenario: {fixtures['capturedPageCount']}/{fixtures['routedPageCount']}",
            f"- Dedicated route names observed before scenario validation: {fixtures['observedDedicatedVisualRouteCount']}",
            f"- Registered fixture IDs without a dedicated route: {fixtures['unroutedRegisteredFixtureCount']}",
            f"- Registered pages without a dedicated route: {fixtures['unroutedPageCount']} ({unrouted_pages})",
            f"- Full Fixture Registry coverage: {'yes' if fixtures['fullFixtureRegistryCoverage'] else 'no'}",
            "",
            "A route or page is captured only when at least one screenshot successfully",
            "matches its expected route, axes, and size contract. Merely observing a",
            "canonical filename does not make an undersized or unsupported image captured.",
            "",
            "Appearance, locale, size, and inspector repetitions are separate visual scenarios",
            "for each registry-derived page/state route. Full fixture coverage is true only",
            "when at least one successfully matched scenario exists for every registered ID;",
            "full scenario coverage additionally requires every declared axis combination.",
            "",
            "## Page scenario coverage",
            "",
            "| Page | State | Boundary | Captured | Expected | Missing |",
            "| --- | --- | --- | ---: | ---: | ---: |",
        ]
    )
    pages = scenarios["pages"]
    assert isinstance(pages, list)
    for page in pages:
        assert isinstance(page, dict)
        lines.append(
            f"| {page['page']} | {page['state']} | {page['captureBoundary']} | "
            f"{page['capturedExpectedScenarioCount']} | "
            f"{page['expectedScenarioCount']} | {page['missingExpectedScenarioCount']} |"
        )
    lines.extend(
        [
            "",
            "## Files",
            "",
            "- `pages/<page>/<state>/<appearance>/<locale>/<attachment-name>.png`: contract-named screenshots.",
            "- `unclassified/<sha256>.png.bin`: exact raw bytes of PNG attachments without page metadata; retained but never treated as canonical screenshots or counted as coverage.",
            "- `unclassified-manifest.json`: hashes, dimensions, paths, and attachment counts for retained unclassified PNG bytes.",
            "- `screenshot-manifest.json`: dimensions, paths, SHA-256, and an explicitly caller-supplied (unbound) appBuild label.",
            "- `coverage.json`: complete scenario, fixture-route, source-test, and attachment accounting.",
            "",
            f"Unclassified PNG attachments retained: {attachments['unclassifiedPNGAttachmentCount']}.",
            f"Non-PNG diagnostic attachments omitted: {attachments['ignoredNonPNGAttachmentCount']}.",
            "",
            "## Review boundary",
            "",
            "No screenshot in this pack becomes a target or approval by being exported. Pixel",
            "acceptance still requires an approved target, deterministic diff artifacts, and",
            "a separate human review. Missing scenarios and unclassified images remain explicit",
            "in `coverage.json`.",
        ]
    )
    return "\n".join(lines) + "\n"


def remove_export_root(export_root: Path, output_root: Path) -> None:
    if export_root.parent != output_root or export_root.name != ".xcresult-attachments":
        raise ReviewPackError(f"refusing to remove unexpected export root: {export_root}")
    if export_root.is_symlink() or not export_root.is_dir():
        raise ReviewPackError(f"refusing to remove unsafe export root: {export_root}")
    shutil.rmtree(export_root)


def write_reproducible_archive(output_root: Path) -> Path:
    archive = output_root / ARCHIVE_NAME
    temporary = output_root / f".{ARCHIVE_NAME}.tmp"
    if archive.exists() or archive.is_symlink() or temporary.exists() or temporary.is_symlink():
        raise ReviewPackError("archive destination unexpectedly exists")
    files = sorted(
        path
        for path in output_root.rglob("*")
        if path.is_file() and path not in {archive, temporary}
    )
    try:
        with zipfile.ZipFile(
            temporary,
            mode="w",
            compression=zipfile.ZIP_STORED,
        ) as bundle:
            for path in files:
                if path.is_symlink():
                    raise ReviewPackError(f"refusing to archive symlink: {path}")
                relative = path.relative_to(output_root).as_posix()
                info = zipfile.ZipInfo(
                    filename=f"{ARCHIVE_ROOT}/{relative}",
                    date_time=FIXED_ZIP_TIMESTAMP,
                )
                info.create_system = 3
                info.external_attr = (stat.S_IFREG | 0o644) << 16
                # PNGs are already compressed. Stored entries avoid zlib-version
                # drift so identical evidence produces identical archive bytes.
                info.compress_type = zipfile.ZIP_STORED
                bundle.writestr(
                    info,
                    path.read_bytes(),
                    compress_type=zipfile.ZIP_STORED,
                )
        temporary.chmod(0o644)
        os.replace(temporary, archive)
    except Exception:
        if temporary.exists() and not temporary.is_symlink():
            temporary.unlink()
        raise
    return archive


def _safe_cleanup_created_output(output_root: Path, created: bool) -> None:
    if not created or not output_root.exists() or output_root.is_symlink():
        return
    if output_root.parent.resolve(strict=True) != output_root.parent:
        return
    shutil.rmtree(output_root)


Exporter = Callable[[Path, Path], None]
SummaryReader = Callable[[Path], object]


def package_visual_review(
    xcresult_value: Path,
    output_value: Path,
    app_build_value: str,
    *,
    exporter: Exporter = export_xcresult_attachments,
    summary_reader: SummaryReader = read_xcresult_summary,
    fixture_registry: Path = FIXTURE_REGISTRY,
) -> Path:
    app_build = validate_app_build(app_build_value)
    xcresult = validate_input_xcresult(xcresult_value)
    output_root = validate_output_root(output_value, xcresult)
    fixture_ids = load_fixture_ids(fixture_registry)
    test_summary = normalize_xcresult_summary(summary_reader(xcresult))

    created = False
    try:
        output_root.mkdir(mode=0o700)
        created = True
        export_root = output_root / ".xcresult-attachments"
        exporter(xcresult, export_root)
        build_artifacts(
            export_root,
            output_root,
            app_build,
            fixture_ids,
            test_summary,
        )
        remove_export_root(export_root, output_root)
        archive = write_reproducible_archive(output_root)
        output_root.chmod(0o755)
        return archive
    except Exception:
        _safe_cleanup_created_output(output_root, created)
        raise


def parse_arguments(arguments: Iterable[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Export Vela visual screenshot evidence from one xcresult into a "
            "truthful, reproducible review pack."
        ),
        epilog=(
            "The xcresult and output paths must be absolute, and the output "
            "directory must not exist. Example: package_visual_review.py "
            "--xcresult /tmp/Vela.xcresult --output-dir /tmp/Vela-review "
            "--app-build abc123-dirty. --app-build is an unverified, "
            "caller-supplied label; the package never presents it as observed "
            "xcresult build metadata."
        ),
    )
    parser.add_argument("--xcresult", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--app-build", required=True)
    return parser.parse_args(arguments)


def main(arguments: Iterable[str] | None = None) -> int:
    args = parse_arguments(arguments)
    try:
        archive = package_visual_review(
            args.xcresult,
            args.output_dir,
            args.app_build,
        )
    except (ReviewPackError, OSError, subprocess.SubprocessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"reviewPack={archive.parent}")
    print(f"reviewArchive={archive}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
