#!/usr/bin/env python3
"""Capture the current dedicated Vela visual build without XCTest automation.

This is a review-evidence fallback for an interactive macOS host whose XCTest
automation channel is unavailable.  It launches only the Debug visual bundle,
addresses every operation by the exact child PID, captures app-owned windows or
AX surfaces, and binds the result to the observed executable SHA-256.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import plistlib
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import zipfile
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

from PIL import Image, ImageDraw, ImageFont, ImageOps

from package_visual_review import (
    APPEARANCES,
    FIXED_ZIP_TIMESTAMP,
    INDEPENDENT_MINIMUM_PIXEL_DIMENSIONS,
    INDEPENDENT_ROUTES,
    LOCALES,
    MAIN_ROUTES,
    ReviewPackError,
    ScreenshotName,
    _expected_scenarios,
    _match_expected_scenario,
    load_fixture_defaults,
    load_fixture_ids,
    main_window_sizes_for_route,
    parse_suggested_screenshot_name,
    png_dimensions,
    sha256,
    verify_png_decode,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
HELPER_SOURCE = REPOSITORY_ROOT / "script/visual_capture_helper.swift"
MANIFEST_VALIDATOR = (
    REPOSITORY_ROOT
    / "Docs/V1/Vela-Visual-Recovery-v2-Codex-Pack/scripts/validate_screenshot_manifest.py"
)
PRODUCTION_BUNDLE_IDENTIFIER = "dev.yilin.Vela"
EXPECTED_BUNDLE_IDENTIFIER = "dev.yilin.Vela.VisualTests"
DEFAULT_OUTPUT = (
    REPOSITORY_ROOT / "VisualRecovery/Vela-Visual-Review-Current-20260715"
)
SAFE_EXECUTABLE_NAME = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
FIXED_DATE, FIXED_UUID_SEED = load_fixture_defaults()
MAX_HELPER_OUTPUT = 256 * 1024
CAPTURE_MAX_ATTEMPTS = 6
CAPTURE_RETRY_BASE_DELAY = 1.0
CAPTURE_COOLDOWN_INTERVAL = 96
CAPTURE_COOLDOWN_SECONDS = 2.0
APP_TERMINATION_SETTLE_SECONDS = 0.05
ARCHIVES_DIRECTORY = "archives"
OVERVIEW_ARCHIVE_NAME = "Vela-Visual-Review-00-Overview.zip"
SAFE_PAGE_NAME = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
MENU_STATUS_TITLES = {
    "loaded": {
        "en": "Running · System Proxy",
        "zh-Hans": "运行中 · 系统代理",
    },
    "pendingMutation": {
        "en": "Applying network change…",
        "zh-Hans": "正在应用网络更改…",
    },
    "partialFailure": {
        "en": "Running · Needs attention",
        "zh-Hans": "运行中 · 需要处理",
    },
    "failure": {
        "en": "Runtime unavailable",
        "zh-Hans": "运行时不可用",
    },
    "stale": {
        "en": "Status may be out of date",
        "zh-Hans": "状态可能已过期",
    },
}


class DirectCaptureError(RuntimeError):
    pass


@dataclass(frozen=True)
class AppBundle:
    path: Path
    executable: Path
    bundle_identifier: str
    executable_sha256: str


@dataclass(frozen=True)
class Scenario:
    page: str
    state: str
    fixture_identifier: str
    appearance: str
    locale: str
    inspector: str
    capture_boundary: str
    window: str
    expected_id: str
    point_size: tuple[int, int] | None

    @property
    def fixture_id(self) -> str:
        return self.fixture_identifier


@dataclass
class RunningApp:
    process: subprocess.Popen[bytes]
    log_path: Path


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace(
        "+00:00", "Z"
    )


def regular_file(path: Path, label: str) -> Path:
    if path.is_symlink():
        raise DirectCaptureError(f"{label} cannot be a symlink: {path}")
    try:
        mode = path.stat().st_mode
    except FileNotFoundError as error:
        raise DirectCaptureError(f"{label} is missing: {path}") from error
    if not stat.S_ISREG(mode):
        raise DirectCaptureError(f"{label} is not a regular file: {path}")
    return path


def validate_app_bundle(value: Path) -> AppBundle:
    if not value.is_absolute():
        raise DirectCaptureError("--app must be an absolute path")
    if value.is_symlink():
        raise DirectCaptureError("--app cannot be a symlink")
    try:
        app = value.resolve(strict=True)
    except FileNotFoundError as error:
        raise DirectCaptureError(f"app bundle does not exist: {value}") from error
    if app.suffix != ".app" or not app.is_dir():
        raise DirectCaptureError(f"--app must be a .app directory: {app}")

    info_path = regular_file(app / "Contents/Info.plist", "Info.plist")
    try:
        with info_path.open("rb") as stream:
            info = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException) as error:
        raise DirectCaptureError(f"invalid app Info.plist: {error}") from error
    if not isinstance(info, dict):
        raise DirectCaptureError("app Info.plist must decode to a dictionary")

    bundle_identifier = info.get("CFBundleIdentifier")
    if bundle_identifier != EXPECTED_BUNDLE_IDENTIFIER:
        raise DirectCaptureError(
            "refusing to capture a non-dedicated bundle: expected "
            f"{EXPECTED_BUNDLE_IDENTIFIER}, found {bundle_identifier!r}"
        )
    if bundle_identifier == PRODUCTION_BUNDLE_IDENTIFIER:
        raise DirectCaptureError("the production Vela bundle is never a capture target")

    executable_name = info.get("CFBundleExecutable")
    if not isinstance(executable_name, str) or not SAFE_EXECUTABLE_NAME.fullmatch(
        executable_name
    ):
        raise DirectCaptureError("Info.plist has an unsafe CFBundleExecutable")
    executable = regular_file(
        app / "Contents/MacOS" / executable_name,
        "app executable",
    ).resolve(strict=True)
    try:
        executable.relative_to(app)
    except ValueError as error:
        raise DirectCaptureError("app executable resolves outside the bundle") from error
    if not os.access(executable, os.X_OK):
        raise DirectCaptureError(f"app executable is not executable: {executable}")

    return AppBundle(
        path=app,
        executable=executable,
        bundle_identifier=bundle_identifier,
        executable_sha256=sha256(executable),
    )


def validate_output(value: Path) -> Path:
    if not value.is_absolute():
        raise DirectCaptureError("--output-dir must be an absolute path")
    if value.name in {"", ".", ".."}:
        raise DirectCaptureError("--output-dir must name a new directory")
    if value.exists() or value.is_symlink():
        raise DirectCaptureError(f"output directory must not already exist: {value}")
    try:
        parent = value.parent.resolve(strict=True)
    except FileNotFoundError as error:
        raise DirectCaptureError(
            f"output parent directory does not exist: {value.parent}"
        ) from error
    if not parent.is_dir():
        raise DirectCaptureError(f"output parent is not a directory: {parent}")
    return parent / value.name


def planned_scenarios(pages: set[str] | None = None) -> list[Scenario]:
    scenarios: list[Scenario] = []
    for route in MAIN_ROUTES:
        if pages is not None and route.page not in pages:
            continue
        for inspector in route.inspectors:
            for locale in LOCALES:
                for appearance in APPEARANCES:
                    for width, height in main_window_sizes_for_route(route):
                        expected_id = (
                            f"{route.page}__{route.state}__{appearance}__{locale}__"
                            f"window-{width}x{height}__{inspector}"
                        )
                        scenarios.append(
                            Scenario(
                                page=route.page,
                                state=route.state,
                                fixture_identifier=route.fixture_id,
                                appearance=appearance,
                                locale=locale,
                                inspector=inspector,
                                capture_boundary=route.capture_boundary,
                                window=f"{width}x{height}",
                                expected_id=expected_id,
                                point_size=(width, height),
                            )
                        )
    for route in INDEPENDENT_ROUTES:
        if pages is not None and route.page not in pages:
            continue
        for inspector in route.inspectors:
            for locale in LOCALES:
                for appearance in APPEARANCES:
                    expected_id = (
                        f"{route.page}__{route.state}__{appearance}__{locale}__"
                        f"{route.capture_boundary}__{inspector}"
                    )
                    scenarios.append(
                        Scenario(
                            page=route.page,
                            state=route.state,
                            fixture_identifier=route.fixture_id,
                            appearance=appearance,
                            locale=locale,
                            inspector=inspector,
                            capture_boundary=route.capture_boundary,
                            window="1280x820",
                            expected_id=expected_id,
                            point_size=None,
                        )
                    )

    expected_routes = _expected_scenarios()
    expected = {
        identifier
        for identifier, route in expected_routes.items()
        if pages is None or route.page in pages
    }
    actual = {scenario.expected_id for scenario in scenarios}
    if len(scenarios) != len(expected) or len(actual) != len(expected) or actual != expected:
        raise DirectCaptureError(
            "direct capture plan differs from the registry-derived scenario matrix"
        )
    return scenarios


def run_checked(
    command: list[str],
    *,
    timeout: float,
    environment: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=environment,
        )
    except subprocess.TimeoutExpired as error:
        raise DirectCaptureError(f"command timed out: {command[0]}") from error
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).strip()
        if len(detail) > 4000:
            detail = detail[-4000:]
        raise DirectCaptureError(
            f"command failed ({completed.returncode}): {' '.join(command[:3])}: {detail}"
        )
    return completed


def compile_helper(temporary_root: Path) -> Path:
    source = regular_file(HELPER_SOURCE, "visual capture helper source")
    helper = temporary_root / "vela-visual-capture-helper"
    cache = temporary_root / "swift-module-cache"
    cache.mkdir(mode=0o700)
    run_checked(
        [
            "/usr/bin/xcrun",
            "swiftc",
            "-module-cache-path",
            str(cache),
            str(source),
            "-o",
            str(helper),
        ],
        timeout=120,
    )
    regular_file(helper, "compiled visual capture helper")
    if not os.access(helper, os.X_OK):
        raise DirectCaptureError("compiled visual capture helper is not executable")
    return helper


def helper_command(
    helper: Path,
    arguments: list[str],
    *,
    timeout: float = 20,
) -> str:
    completed = run_checked([str(helper), *arguments], timeout=timeout)
    output = completed.stdout.strip()
    if len(output.encode("utf-8")) > MAX_HELPER_OUTPUT:
        raise DirectCaptureError("visual capture helper output is unexpectedly large")
    return output


def helper_json(
    helper: Path,
    arguments: list[str],
    *,
    timeout: float = 20,
) -> dict[str, object]:
    output = helper_command(helper, arguments, timeout=timeout)
    try:
        value = json.loads(output)
    except json.JSONDecodeError as error:
        raise DirectCaptureError(f"invalid helper JSON: {output[:500]!r}") from error
    if not isinstance(value, dict):
        raise DirectCaptureError("visual capture helper JSON must be an object")
    return value


def finite_number(value: object, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise DirectCaptureError(f"{label} must be a number")
    result = float(value)
    if not math.isfinite(result):
        raise DirectCaptureError(f"{label} must be finite")
    return result


def validate_rect(value: dict[str, object], label: str) -> dict[str, float]:
    result = {
        key: finite_number(value.get(key), f"{label}.{key}")
        for key in ("x", "y", "width", "height")
    }
    if result["width"] <= 0 or result["height"] <= 0:
        raise DirectCaptureError(f"{label} must have positive dimensions")
    return result


def wait_for_window(
    helper: Path,
    pid: int,
    *,
    title: str | None = None,
    timeout: float = 12,
) -> dict[str, object]:
    deadline = time.monotonic() + timeout
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        arguments = ["window", str(pid)]
        if title is not None:
            arguments.append(title)
        try:
            return helper_json(helper, arguments, timeout=3)
        except DirectCaptureError as error:
            last_error = error
            time.sleep(0.08)
    raise DirectCaptureError(
        f"window did not appear for PID {pid}"
        + (f" with title {title!r}" if title else "")
        + (f": {last_error}" if last_error else "")
    )


def activate_app(
    helper: Path,
    running: RunningApp,
    *,
    timeout: float = 10,
) -> None:
    """Wait for AppKit/LaunchServices registration before activating the PID."""
    deadline = time.monotonic() + timeout
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        ensure_child_running(running, "LaunchServices registration")
        try:
            helper_command(
                helper,
                ["activate", str(running.process.pid)],
                timeout=3,
            )
            return
        except DirectCaptureError as error:
            last_error = error
            time.sleep(0.08)
    raise DirectCaptureError(
        f"dedicated visual app could not be activated: {last_error}"
    )


def find_settings_window(
    helper: Path,
    pid: int,
    locale: str,
    fixture_id: str | None = None,
    *,
    timeout: float = 10,
) -> dict[str, object]:
    if fixture_id is not None:
        identifier = f"visual.ready.{fixture_id}"
        try:
            return helper_json(
                helper,
                ["window-id", str(pid), identifier],
                timeout=3,
            )
        except DirectCaptureError:
            # Keep the localized-title lookup as a compatibility fallback for
            # older fixture hosts that do not attach the ready marker to AXWindow.
            pass
    titles = ["设置", "Settings"] if locale == "zh-Hans" else ["Settings", "设置"]
    deadline = time.monotonic() + timeout
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        for title in titles:
            try:
                return helper_json(helper, ["window", str(pid), title], timeout=3)
            except DirectCaptureError as error:
                last_error = error
        time.sleep(0.08)
    raise DirectCaptureError(
        f"localized Settings window did not appear for PID {pid}: {last_error}"
    )


def assert_no_existing_exact_process(executable: Path) -> None:
    completed = run_checked(
        ["/bin/ps", "-axo", "pid=,command="],
        timeout=10,
    )
    target = str(executable)
    matches = []
    for line in completed.stdout.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        fields = stripped.split(None, 1)
        if len(fields) == 2 and (
            fields[1] == target or fields[1].startswith(target + " ")
        ):
            matches.append(fields[0])
    if matches:
        raise DirectCaptureError(
            "the exact dedicated visual executable is already running as PID(s): "
            + ", ".join(matches)
        )


OVERVIEW_ACCESSIBILITY_PROBE_IDENTIFIERS = (
    "overview.root",
    "overview.header",
    "overview.nodeHeader",
    "overview.connectionCore",
    "overview.route",
    "overview.route.nodeMenu",
    "overview.metrics",
    "overview.metrics.connections",
    "overview.accessibility.increasedContrast",
    "overview.accessibility.reduceMotion",
)


def visual_launch_arguments(
    scenario: Scenario,
    *,
    overview_accessibility_probe: bool = False,
) -> list[str]:
    apple_locale = "zh_CN" if scenario.locale == "zh-Hans" else "en_US"
    interface_style = "Dark" if scenario.appearance == "dark" else "Light"
    arguments = [
        "-ApplePersistenceIgnoreState",
        "YES",
        "-AppleInterfaceStyle",
        interface_style,
        "-AppleLanguages",
        f"({scenario.locale})",
        "-AppleLocale",
        apple_locale,
        "-VelaVisualTestMode",
        "YES",
        "-VelaFixture",
        scenario.fixture_id,
        "-VelaPage",
        scenario.page,
        "-VelaState",
        scenario.state,
        "-VelaAppearance",
        scenario.appearance,
        "-VelaLocale",
        scenario.locale,
        "-VelaWindow",
        scenario.window,
        "-VelaInspector",
        scenario.inspector,
        "-VelaFixedDate",
        FIXED_DATE,
        "-VelaUUIDSeed",
        FIXED_UUID_SEED,
    ]
    if overview_accessibility_probe:
        arguments.extend(
            [
                "-VelaOverviewIncreaseContrast",
                "YES",
                "-VelaOverviewReduceMotion",
                "YES",
            ]
        )
    return arguments


def launch_app(
    app: AppBundle,
    scenario: Scenario,
    log_path: Path,
    *,
    overview_accessibility_probe: bool = False,
) -> RunningApp:
    regular_file(app.executable, "dedicated app executable")
    log_stream = log_path.open("wb")
    try:
        process = subprocess.Popen(
            [
                str(app.executable),
                *visual_launch_arguments(
                    scenario,
                    overview_accessibility_probe=overview_accessibility_probe,
                ),
            ],
            stdin=subprocess.DEVNULL,
            stdout=log_stream,
            stderr=subprocess.STDOUT,
            cwd=str(app.path.parent),
            close_fds=True,
        )
    except Exception:
        log_stream.close()
        raise
    log_stream.close()
    time.sleep(0.08)
    if process.poll() is not None:
        raise DirectCaptureError(
            f"dedicated visual app exited immediately with {process.returncode}: "
            + read_log_tail(log_path)
        )
    return RunningApp(process=process, log_path=log_path)


def read_log_tail(path: Path, limit: int = 8000) -> str:
    try:
        data = path.read_bytes()
    except OSError:
        return "(app log unavailable)"
    return data[-limit:].decode("utf-8", errors="replace").strip()


def terminate_app(running: RunningApp) -> None:
    process = running.process
    if process.poll() is not None:
        return
    process.send_signal(signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        # This kills only the exact child process created by this script.
        process.kill()
        process.wait(timeout=5)


def clear_dedicated_saved_state(bundle_identifier: str) -> None:
    if bundle_identifier != EXPECTED_BUNDLE_IDENTIFIER:
        raise DirectCaptureError("refusing to clear a non-dedicated preferences domain")
    completed = subprocess.run(
        ["/usr/bin/defaults", "delete", EXPECTED_BUNDLE_IDENTIFIER],
        capture_output=True,
        text=True,
        timeout=10,
    )
    if completed.returncode not in {0, 1}:
        detail = (completed.stderr or completed.stdout).strip()
        raise DirectCaptureError(f"could not clear dedicated defaults: {detail}")

    parent = Path.home() / "Library/Saved Application State"
    saved_state = parent / f"{EXPECTED_BUNDLE_IDENTIFIER}.savedState"
    if saved_state.is_symlink():
        raise DirectCaptureError(f"refusing to remove symlinked saved state: {saved_state}")
    if saved_state.exists():
        if not saved_state.is_dir():
            raise DirectCaptureError(
                f"dedicated saved state is not a directory: {saved_state}"
            )
        shutil.rmtree(saved_state)


def ensure_child_running(running: RunningApp, context: str) -> None:
    return_code = running.process.poll()
    if return_code is not None:
        raise DirectCaptureError(
            f"dedicated visual app exited during {context} with {return_code}: "
            + read_log_tail(running.log_path)
        )


def capture_window_id(
    window_id: int,
    destination: Path,
    *,
    timeout: float = 6,
) -> None:
    if window_id <= 0:
        raise DirectCaptureError("CGWindow ID must be positive")
    if destination.exists() or destination.is_symlink():
        raise DirectCaptureError(f"temporary screenshot path is not absent: {destination}")
    deadline = time.monotonic() + timeout
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        try:
            run_checked(
                [
                    "/usr/sbin/screencapture",
                    "-x",
                    "-o",
                    "-l",
                    str(window_id),
                    str(destination),
                ],
                timeout=20,
            )
            regular_file(destination, "captured window PNG")
            return
        except DirectCaptureError as error:
            last_error = error
            if destination.exists() and not destination.is_symlink():
                destination.unlink()
            time.sleep(0.2)
    raise DirectCaptureError(
        f"could not capture CGWindow {window_id} after retries: {last_error}"
    )


def capture_region(rect: dict[str, float], destination: Path) -> None:
    x = math.floor(rect["x"])
    y = math.floor(rect["y"])
    width = math.ceil(rect["x"] + rect["width"]) - x
    height = math.ceil(rect["y"] + rect["height"]) - y
    if width < 80 or height < 80 or width > 800 or height > 1200:
        raise DirectCaptureError(
            f"menu capture boundary is outside the privacy gate: {width}x{height} points"
        )
    if destination.exists() or destination.is_symlink():
        raise DirectCaptureError(f"temporary screenshot path is not absent: {destination}")
    run_checked(
        [
            "/usr/sbin/screencapture",
            "-x",
            f"-R{x},{y},{width},{height}",
            str(destination),
        ],
        timeout=20,
    )
    regular_file(destination, "captured AX region PNG")


def image_dimensions(path: Path) -> tuple[int, int]:
    try:
        dimensions = png_dimensions(path)
        if dimensions is None:
            raise DirectCaptureError(f"capture is not a PNG: {path.name}")
        verify_png_decode(path, dimensions)
    except ReviewPackError as error:
        raise DirectCaptureError(str(error)) from error
    return dimensions


def window_id(value: dict[str, object], label: str) -> int:
    raw = value.get("id")
    if isinstance(raw, bool) or not isinstance(raw, int) or raw <= 0:
        raise DirectCaptureError(f"{label} has no positive CGWindow ID")
    return raw


def open_settings(helper: Path, pid: int) -> None:
    # Prefer the control's public AXPress action. It is scoped to the exact PID
    # and avoids both grouped hit-test geometry and global keyboard focus races.
    try:
        helper_command(
            helper,
            ["press-id", str(pid), "sidebar.settings"],
            timeout=6,
        )
    except DirectCaptureError:
        helper_command(helper, ["open-settings", str(pid)], timeout=6)


def select_tun_category(helper: Path, pid: int) -> None:
    try:
        helper_command(
            helper,
            ["press-id", str(pid), "settings.action.tun"],
            timeout=8,
        )
    except DirectCaptureError:
        helper_command(
            helper,
            ["click-id", str(pid), "settings.action.tun"],
            timeout=8,
        )


def capture_main_surface(
    helper: Path,
    running: RunningApp,
    scenario: Scenario,
    work_png: Path,
) -> dict[str, object]:
    pid = running.process.pid
    helper_command(
        helper,
        ["wait-id", str(pid), f"visual.ready.{scenario.fixture_id}", "12"],
        timeout=16,
    )
    helper_command(helper, ["activate", str(pid)], timeout=5)
    assert scenario.point_size is not None
    expected_width, expected_height = scenario.point_size
    geometry_deadline = time.monotonic() + 6
    record: dict[str, object] | None = None
    rect: dict[str, float] | None = None
    while time.monotonic() < geometry_deadline:
        record = wait_for_window(helper, pid, timeout=2)
        rect = validate_rect(record, "mainWindow")
        if (
            abs(rect["width"] - expected_width) <= 1
            and abs(rect["height"] - expected_height) <= 1
        ):
            break
        time.sleep(0.08)
    if record is None or rect is None or (
        abs(rect["width"] - expected_width) > 1
        or abs(rect["height"] - expected_height) > 1
    ):
        raise DirectCaptureError(
            f"{scenario.expected_id}: main window is "
            f"{rect['width'] if rect else 'unknown'}x"
            f"{rect['height'] if rect else 'unknown'} "
            f"points, expected {expected_width}x{expected_height}"
        )
    time.sleep(0.35)
    capture_window_id(window_id(record, "mainWindow"), work_png)
    dimensions = image_dimensions(work_png)
    allowed = {
        (expected_width, expected_height),
        (expected_width * 2, expected_height * 2),
    }
    if dimensions not in allowed:
        raise DirectCaptureError(
            f"{scenario.expected_id}: PNG dimensions {dimensions} are not 1x or 2x "
            f"for {scenario.point_size}"
        )
    return {"windowPointBounds": rect, "pixelDimensions": list(dimensions)}


def crop_sheet_from_window(
    source: Path,
    destination: Path,
    *,
    window_rect: dict[str, float],
    sheet_rect: dict[str, float],
) -> None:
    tolerance = 2.0
    if (
        sheet_rect["x"] < window_rect["x"] - tolerance
        or sheet_rect["y"] < window_rect["y"] - tolerance
        or sheet_rect["x"] + sheet_rect["width"]
        > window_rect["x"] + window_rect["width"] + tolerance
        or sheet_rect["y"] + sheet_rect["height"]
        > window_rect["y"] + window_rect["height"] + tolerance
    ):
        raise DirectCaptureError(
            "TUN sheet is not contained by the app-owned capture window: "
            f"sheet={sheet_rect}, window={window_rect}"
        )
    with Image.open(source) as image:
        image.load()
        scale = min(
            (1, 2),
            key=lambda candidate: (
                abs(image.width - window_rect["width"] * candidate)
                + abs(image.height - window_rect["height"] * candidate)
            ),
        )
        padding_x = image.width - window_rect["width"] * scale
        padding_y = image.height - window_rect["height"] * scale
        if abs(padding_x) > 16 or abs(padding_y) > 16:
            raise DirectCaptureError(
                "unexpected attached-sheet capture geometry: "
                f"image={image.size}, union={window_rect}, scale={scale}, "
                f"padding={padding_x:.3f}x{padding_y:.3f}"
            )
        left = round(
            (sheet_rect["x"] - window_rect["x"]) * scale + padding_x / 2
        )
        top = round(
            (sheet_rect["y"] - window_rect["y"]) * scale + padding_y / 2
        )
        right = round(left + sheet_rect["width"] * scale)
        bottom = round(top + sheet_rect["height"] * scale)
        left = max(0, min(image.width, left))
        top = max(0, min(image.height, top))
        right = max(0, min(image.width, right))
        bottom = max(0, min(image.height, bottom))
        if right <= left or bottom <= top:
            raise DirectCaptureError("TUN sheet crop is empty")
        image.crop((left, top, right, bottom)).save(destination, format="PNG")


def union_rect(
    first: dict[str, float],
    second: dict[str, float],
) -> dict[str, float]:
    minimum_x = min(first["x"], second["x"])
    minimum_y = min(first["y"], second["y"])
    maximum_x = max(
        first["x"] + first["width"],
        second["x"] + second["width"],
    )
    maximum_y = max(
        first["y"] + first["height"],
        second["y"] + second["height"],
    )
    return {
        "x": minimum_x,
        "y": minimum_y,
        "width": maximum_x - minimum_x,
        "height": maximum_y - minimum_y,
    }


def capture_tun_surface(
    helper: Path,
    running: RunningApp,
    scenario: Scenario,
    work_png: Path,
    secondary_png: Path,
) -> dict[str, object]:
    pid = running.process.pid
    wait_for_window(helper, pid)
    activate_app(helper, running)
    open_settings(helper, pid)
    try:
        helper_command(
            helper,
            ["wait-id", str(pid), "settings.detail.coreNetwork", "10"],
            timeout=14,
        )
    except DirectCaptureError:
        activate_app(helper, running)
        open_settings(helper, pid)
        helper_command(
            helper,
            ["wait-id", str(pid), "settings.detail.coreNetwork", "10"],
            timeout=14,
        )
    select_tun_category(helper, pid)
    helper_command(
        helper,
        ["wait-id", str(pid), f"visual.ready.{scenario.fixture_id}", "12"],
        timeout=16,
    )
    sheet = helper_json(helper, ["sheet", str(pid), "10"], timeout=14)
    sheet_rect = validate_rect(sheet, "tunSheet")

    # An attached NSWindow sheet can share or visually expand its parent's
    # CoreGraphics window even when AX reports a sheet-specific frame. Always
    # capture the localized Settings window and crop to the contained AX sheet
    # boundary; treating the matched CGWindow ID as sheet-only can retain the
    # dimmed parent content around the evidence boundary.
    capture_window = find_settings_window(
        helper,
        pid,
        scenario.locale,
        scenario.fixture_id,
    )
    settings_rect = validate_rect(capture_window, "settingsWindow")
    # screencapture returns the union of an attached sheet and its parent even
    # though CGWindowInfo continues to report the parent's pre-sheet bounds.
    # Model that documented visual union explicitly, then crop to the AX sheet.
    capture_rect = union_rect(settings_rect, sheet_rect)
    capture_method = "cropFromAppOwnedSettingsWindowAndAXSheetUnion"
    capture_window_id(window_id(capture_window, "tunCaptureWindow"), secondary_png)
    crop_sheet_from_window(
        secondary_png,
        work_png,
        window_rect=capture_rect,
        sheet_rect=sheet_rect,
    )

    dimensions = image_dimensions(work_png)
    minimum = INDEPENDENT_MINIMUM_PIXEL_DIMENSIONS[scenario.page]
    if dimensions[0] < minimum[0] or dimensions[1] < minimum[1]:
        raise DirectCaptureError(
            f"{scenario.expected_id}: TUN capture {dimensions} is below {minimum}"
        )
    return {
        "sheetPointBounds": sheet_rect,
        "pixelDimensions": list(dimensions),
        "captureMethod": capture_method,
    }


def capture_menu_surface(
    helper: Path,
    running: RunningApp,
    scenario: Scenario,
    work_png: Path,
) -> dict[str, object]:
    pid = running.process.pid
    wait_for_window(helper, pid)
    menu = helper_json(helper, ["menu", str(pid), "10"], timeout=14)
    raw_titles = menu.get("menuItemTitles")
    if not isinstance(raw_titles, list) or not all(
        isinstance(title, str) for title in raw_titles
    ):
        raise DirectCaptureError(
            f"{scenario.expected_id}: menu AX titles are unavailable"
        )
    expected_status = MENU_STATUS_TITLES.get(scenario.state, {}).get(
        scenario.locale
    )
    if expected_status is None or expected_status not in raw_titles:
        raise DirectCaptureError(
            f"{scenario.expected_id}: expected menu status {expected_status!r} "
            f"was not found in {raw_titles!r}"
        )
    rect = validate_rect(menu, "menu")
    if isinstance(menu.get("id"), int) and not isinstance(menu.get("id"), bool):
        capture_window_id(window_id(menu, "menu"), work_png)
        capture_method = "appOwnedMenuWindowID"
    else:
        capture_region(rect, work_png)
        capture_method = "validatedAXMenuRegion"
    dimensions = image_dimensions(work_png)
    minimum = INDEPENDENT_MINIMUM_PIXEL_DIMENSIONS[scenario.page]
    if dimensions[0] < minimum[0] or dimensions[1] < minimum[1]:
        raise DirectCaptureError(
            f"{scenario.expected_id}: menu capture {dimensions} is below {minimum}"
        )
    return {
        "menuPointBounds": rect,
        "pixelDimensions": list(dimensions),
        "captureMethod": capture_method,
    }


def capture_one(
    app: AppBundle,
    helper: Path,
    scenario: Scenario,
    staging: Path,
    work_root: Path,
    *,
    overview_accessibility_probe: bool = False,
) -> tuple[dict[str, object], dict[str, object]]:
    work_png = work_root / "capture.png"
    secondary_png = work_root / "secondary.png"
    log_path = work_root / "app.log"
    for path in (work_png, secondary_png, log_path):
        if path.exists() and not path.is_symlink():
            path.unlink()
    clear_dedicated_saved_state(app.bundle_identifier)
    running = launch_app(
        app,
        scenario,
        log_path,
        overview_accessibility_probe=overview_accessibility_probe,
    )
    try:
        activate_app(helper, running)
        if overview_accessibility_probe:
            for identifier in OVERVIEW_ACCESSIBILITY_PROBE_IDENTIFIERS:
                helper_command(
                    helper,
                    ["wait-id", str(running.process.pid), identifier, "8"],
                    timeout=20,
                )
        if scenario.capture_boundary == "mainWindow":
            metadata = capture_main_surface(
                helper, running, scenario, work_png
            )
        elif scenario.capture_boundary == "sheet":
            metadata = capture_tun_surface(
                helper, running, scenario, work_png, secondary_png
            )
        elif scenario.capture_boundary == "menu":
            metadata = capture_menu_surface(helper, running, scenario, work_png)
        else:
            raise DirectCaptureError(
                f"unsupported capture boundary: {scenario.capture_boundary}"
            )
        ensure_child_running(running, scenario.expected_id)
    except Exception as error:
        tail = read_log_tail(log_path)
        if tail:
            raise DirectCaptureError(f"{error}\napp log tail:\n{tail}") from error
        raise
    finally:
        terminate_app(running)
        # A full review run launches more than 1,600 short-lived AppKit
        # processes. Give LaunchServices a small window to retire each process
        # registration before the next bundle instance starts.
        time.sleep(APP_TERMINATION_SETTLE_SECONDS)
        clear_dedicated_saved_state(app.bundle_identifier)

    dimensions = image_dimensions(work_png)
    canonical_name = (
        f"{scenario.page}__{scenario.state}__{scenario.appearance}__"
        f"{scenario.locale}__{dimensions[0]}x{dimensions[1]}__"
        f"{scenario.inspector}.png"
    )
    parsed = parse_suggested_screenshot_name(canonical_name)
    if parsed is None:
        raise DirectCaptureError(f"generated screenshot name is invalid: {canonical_name}")
    matched, reason = _match_expected_scenario(parsed)
    if matched != scenario.expected_id or reason is not None:
        raise DirectCaptureError(
            f"{canonical_name} does not match {scenario.expected_id}: {reason}"
        )

    destination = (
        staging
        / "pages"
        / scenario.page
        / scenario.state
        / scenario.appearance
        / scenario.locale
        / canonical_name
    )
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() or destination.is_symlink():
        raise DirectCaptureError(f"duplicate screenshot destination: {destination}")
    os.replace(work_png, destination)
    destination.chmod(0o644)
    relative = destination.relative_to(staging).as_posix()
    screenshot = {
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
    source = {
        "scenarioID": scenario.expected_id,
        "screenshotID": parsed.identifier,
        "fixtureID": scenario.fixture_id,
        "captureBoundary": scenario.capture_boundary,
        **metadata,
    }
    return screenshot, source


def write_json(path: Path, value: object) -> None:
    path.write_text(
        json.dumps(
            value,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
            allow_nan=False,
        )
        + "\n",
        encoding="utf-8",
    )
    path.chmod(0o644)


def git_snapshot() -> dict[str, object]:
    head = run_checked(
        ["/usr/bin/git", "rev-parse", "HEAD"],
        timeout=10,
    ).stdout.strip()
    status = run_checked(
        ["/usr/bin/git", "status", "--porcelain=v1", "--untracked-files=all"],
        timeout=20,
    ).stdout.splitlines()
    return {
        "head": head,
        "dirty": bool(status),
        "statusEntryCount": len(status),
        "binding": "workspaceSnapshotOnlyNotCryptographicSourceBinding",
    }


def derive_review_boundary(
    staging: Path,
    *,
    expected_commit: str | None = None,
    expected_executable_sha256: str | None = None,
    workspace_clean: bool = False,
) -> dict[str, bool]:
    """Derive evidence claims from artifacts actually present in this run.

    The direct capture command does not manufacture approval, diff, XCTest, or
    source-binding receipts. If a future workflow stages one of those artifacts
    before coverage generation, the claim changes from the observed files
    instead of from a hand-maintained constant.
    """
    regular_files = {
        path.relative_to(staging).as_posix()
        for path in staging.rglob("*")
        if path.is_file() and not path.is_symlink()
    }

    def receipt(name: str) -> dict[str, object] | None:
        if name not in regular_files:
            return None
        try:
            value = json.loads((staging / name).read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError):
            return None
        return value if isinstance(value, dict) else None

    target_receipt = receipt("approved-targets/manifest.json")
    diff_receipt = receipt("diffs/report.json")
    approval_receipt = receipt("human-approval.json")
    xctest_receipt = receipt("xctest-result.json")
    source_receipt = receipt("source-binding.json")
    passing_results = {"passed", "succeeded", "success"}
    source_sha = re.compile(r"^[0-9a-f]{40,64}$")

    return {
        "approvedPixelTargetsIncluded": (
            target_receipt is not None and target_receipt.get("approved") is True
        ),
        "visualDiffIncluded": (
            diff_receipt is not None and diff_receipt.get("complete") is True
        ),
        "humanApprovalIncluded": (
            approval_receipt is not None and approval_receipt.get("approved") is True
        ),
        "xctestPassIncluded": (
            xctest_receipt is not None
            and str(xctest_receipt.get("result", "")).casefold() in passing_results
        ),
        "sourceTreeCryptographicallyBound": (
            source_receipt is not None
            and source_receipt.get("clean") is True
            and workspace_clean
            and isinstance(source_receipt.get("commitSHA"), str)
            and source_sha.fullmatch(str(source_receipt["commitSHA"])) is not None
            and source_receipt.get("commitSHA") == expected_commit
            and isinstance(source_receipt.get("executableSHA256"), str)
            and re.fullmatch(
                r"[0-9a-f]{64}", str(source_receipt["executableSHA256"])
            ) is not None
            and source_receipt.get("executableSHA256")
            == expected_executable_sha256
        ),
    }


def build_coverage(
    *,
    app: AppBundle,
    screenshots: list[dict[str, object]],
    sources: list[dict[str, object]],
    fixture_ids: list[str],
    started_at: str,
    finished_at: str,
    git: dict[str, object],
    accessibility_trusted: bool,
    review_boundary: dict[str, bool],
    pages_filter: set[str] | None = None,
) -> dict[str, object]:
    all_expected = _expected_scenarios()
    expected = {
        identifier: route
        for identifier, route in all_expected.items()
        if pages_filter is None or route.page in pages_filter
    }
    captured_ids = {str(item["scenarioID"]) for item in sources}
    missing = sorted(set(expected) - captured_ids)
    duplicates = sorted(
        identifier
        for identifier, count in Counter(
            str(item["scenarioID"]) for item in sources
        ).items()
        if count > 1
    )
    unexpected = sorted(captured_ids - set(expected))
    expected_count = len(expected)
    if missing or duplicates or unexpected or len(screenshots) != expected_count:
        raise DirectCaptureError(
            "captured evidence does not exactly cover the registry-derived scenario matrix"
        )

    selected_routes = tuple(
        route
        for route in (*MAIN_ROUTES, *INDEPENDENT_ROUTES)
        if pages_filter is None or route.page in pages_filter
    )
    fixture_set = {
        fixture_id
        for fixture_id in fixture_ids
        if pages_filter is None or fixture_id.split(".", 1)[0] in pages_filter
    }
    route_ids = {route.fixture_id for route in selected_routes}
    fixture_ids = sorted(fixture_set)
    registered_pages = {identifier.split(".", 1)[0] for identifier in fixture_ids}
    routed_pages = {route.page for route in selected_routes}
    captured_fixture_ids = {
        str(item["fixtureID"])
        for item in sources
        if str(item["scenarioID"]) in expected
    }
    captured_pages = {
        fixture_id.split(".", 1)[0] for fixture_id in captured_fixture_ids
    }
    captured_by_fixture = Counter(
        str(item["fixtureID"]) for item in sources
    )
    expected_by_fixture = Counter(route.fixture_id for route in expected.values())
    pages = []
    for route in selected_routes:
        pages.append(
            {
                "fixtureID": route.fixture_id,
                "page": route.page,
                "state": route.state,
                "captureBoundary": route.capture_boundary,
                "capturedScenarioCount": captured_by_fixture[route.fixture_id],
                "expectedScenarioCount": expected_by_fixture[route.fixture_id],
                "complete": (
                    captured_by_fixture[route.fixture_id]
                    == expected_by_fixture[route.fixture_id]
                ),
            }
        )

    complete = (
        not missing
        and not duplicates
        and not unexpected
        and len(screenshots) == expected_count
    )
    whole_screen_used = any(
        item.get("captureMethod") == "wholeScreen" for item in sources
    )

    return {
        "schemaVersion": 1,
        "coverageClaim": "currentDirectVisualScenarioReviewEvidence",
        "provenance": {
            "captureMode": "pidScopedAccessibilityAndCoreGraphics",
            "captureFallbackReason": "hostXCTestAutomationChannelTimeout",
            "xctestResultClaimed": review_boundary["xctestPassIncluded"],
            "bundleIdentifier": app.bundle_identifier,
            "appExecutableSHA256": app.executable_sha256,
            "binaryBinding": "observedExecutableSHA256",
            "captureStartedAt": started_at,
            "captureFinishedAt": finished_at,
            "accessibilityTrusted": accessibility_trusted,
            "git": git,
        },
        "visualScenarioCoverage": {
            "expectedScenarioCount": len(expected),
            "capturedExpectedScenarioCount": len(captured_ids),
            "missingExpectedScenarioCount": len(missing),
            "unexpectedScreenshotCount": len(unexpected),
            "duplicateExpectedScenarioCount": len(duplicates),
            "complete": complete,
            "missingExpectedScenarios": missing,
            "unexpectedScreenshots": unexpected,
            "duplicateExpectedScenarios": duplicates,
            "pages": pages,
        },
        "fixtureRouteCoverage": {
            "registeredFixtureCount": len(fixture_ids),
            "registeredPageCount": len(registered_pages),
            "dedicatedVisualRouteCount": len(route_ids),
            "routedPageCount": len(routed_pages),
            "unroutedRegisteredFixtureCount": len(fixture_set - route_ids),
            "unroutedPageCount": len(registered_pages - routed_pages),
            "unroutedPages": sorted(registered_pages - routed_pages),
            "capturedDedicatedVisualRouteCount": len(captured_fixture_ids & route_ids),
            "capturedPageCount": len(captured_pages & routed_pages),
            "fullFixtureRegistryCoverage": captured_fixture_ids == fixture_set,
            "dedicatedVisualRouteIDs": sorted(route_ids),
            "unroutedRegisteredFixtureIDs": sorted(fixture_set - route_ids),
        },
        "captureBoundaries": {
            "mainWindow": "exact app-owned CGWindow ID",
            "settingsWindow": "localized app-owned CGWindow ID",
            "sheet": "app-owned sheet window or crop contained within Settings window",
            "menu": "validated Vela AXMenu window or bounded AX menu region",
            "wholeScreenCaptureUsed": whole_screen_used,
        },
        "screenshotSources": sorted(sources, key=lambda item: str(item["scenarioID"])),
        "reviewBoundary": review_boundary,
    }


def load_font(size: int) -> ImageFont.ImageFont:
    candidates = [
        Path("/System/Library/Fonts/Supplemental/Arial.ttf"),
        Path("/System/Library/Fonts/SFNS.ttf"),
    ]
    for candidate in candidates:
        try:
            return ImageFont.truetype(str(candidate), size=size)
        except OSError:
            continue
    return ImageFont.load_default()


def make_contact_sheet(
    items: list[dict[str, object]],
    staging: Path,
    destination: Path,
    title: str,
    *,
    columns: int,
) -> None:
    if not items:
        raise DirectCaptureError(f"contact sheet has no items: {title}")
    tile_width, tile_height = 500, 360
    header_height = 70
    rows = math.ceil(len(items) / columns)
    canvas = Image.new(
        "RGB",
        (columns * tile_width, header_height + rows * tile_height),
        (242, 243, 245),
    )
    draw = ImageDraw.Draw(canvas)
    title_font = load_font(26)
    label_font = load_font(14)
    draw.text((24, 20), title, fill=(25, 27, 31), font=title_font)
    for index, item in enumerate(items):
        row, column = divmod(index, columns)
        origin_x = column * tile_width
        origin_y = header_height + row * tile_height
        path = regular_file(staging / str(item["path"]), "contact-sheet source")
        with Image.open(path) as source:
            source.load()
            thumbnail = ImageOps.contain(source.convert("RGB"), (464, 290))
        image_x = origin_x + (tile_width - thumbnail.width) // 2
        image_y = origin_y + 10
        canvas.paste(thumbnail, (image_x, image_y))
        label = str(item["id"])
        if len(label) > 68:
            label = label[:65] + "..."
        draw.text(
            (origin_x + 18, origin_y + 312),
            label,
            fill=(32, 34, 38),
            font=label_font,
        )
    destination.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(destination, format="JPEG", quality=90, optimize=True)
    destination.chmod(0o644)


def build_contact_sheets(
    screenshots: list[dict[str, object]], staging: Path
) -> None:
    grouped: dict[str, list[dict[str, object]]] = defaultdict(list)
    for item in screenshots:
        grouped[str(item["page"])].append(item)
    contact_root = staging / "contact-sheets"
    contact_root.mkdir(mode=0o755)
    representatives = []
    page_order = list(dict.fromkeys(
        route.page for route in (*MAIN_ROUTES, *INDEPENDENT_ROUTES)
    ))
    for page in page_order:
        items = sorted(grouped[page], key=lambda item: str(item["id"]))
        if not items:
            continue
        make_contact_sheet(
            items,
            staging,
            contact_root / f"{page}.jpg",
            f"Vela · {page} · {len(items)} scenarios",
            columns=3 if len(items) > 4 else 2,
        )
        representatives.append(items[0])
    make_contact_sheet(
        representatives,
        staging,
        contact_root / "ALL-PAGES.jpg",
        "Vela · one representative per routed page",
        columns=3,
    )
    (contact_root / "README.md").write_text(
        "# Contact sheets\n\n"
        "These JPEGs are navigation aids generated from the canonical PNG captures. "
        "Use `../pages/` and `../screenshot-manifest.json` for pixel-level review.\n",
        encoding="utf-8",
    )
    (contact_root / "README.md").chmod(0o644)


def write_review_index(
    screenshots: list[dict[str, object]], staging: Path
) -> None:
    grouped: dict[str, list[dict[str, object]]] = defaultdict(list)
    for item in screenshots:
        grouped[str(item["page"])].append(item)
    lines = [
        "# Vela screenshot index",
        "",
        "Start with [the all-pages contact sheet](contact-sheets/ALL-PAGES.jpg).",
        "Canonical full-resolution PNGs follow.",
        "",
    ]
    page_order = list(dict.fromkeys(
        route.page for route in (*MAIN_ROUTES, *INDEPENDENT_ROUTES)
    ))
    for page in page_order:
        items = sorted(grouped[page], key=lambda item: str(item["id"]))
        if not items:
            continue
        lines.extend(
            [
                f"## {page}",
                "",
                f"[Contact sheet](contact-sheets/{page}.jpg)",
                "",
            ]
        )
        lines.extend(f"- [{item['id']}]({item['path']})" for item in items)
        lines.append("")
    (staging / "REVIEW-INDEX.md").write_text("\n".join(lines), encoding="utf-8")
    (staging / "REVIEW-INDEX.md").chmod(0o644)


def write_readme(
    staging: Path,
    *,
    app: AppBundle,
    coverage: dict[str, object],
) -> None:
    provenance = coverage["provenance"]
    assert isinstance(provenance, dict)
    git = provenance["git"]
    assert isinstance(git, dict)
    fixture = coverage["fixtureRouteCoverage"]
    assert isinstance(fixture, dict)
    scenarios = coverage["visualScenarioCoverage"]
    assert isinstance(scenarios, dict)
    boundaries = coverage["captureBoundaries"]
    assert isinstance(boundaries, dict)
    review = coverage["reviewBoundary"]
    assert isinstance(review, dict)
    captured_count = int(scenarios["capturedExpectedScenarioCount"])
    expected_count = int(scenarios["expectedScenarioCount"])
    main_count = sum(
        int(item["expectedScenarioCount"])
        for item in scenarios["pages"]
        if isinstance(item, dict) and item.get("captureBoundary") == "mainWindow"
    )
    independent_count = expected_count - main_count
    unrouted_pages = ", ".join(fixture["unroutedPages"]) or "none"
    xctest_statement = (
        "A passing XCTest receipt is included."
        if review["xctestPassIncluded"]
        else "No passing XCTest receipt is included by this direct-capture run."
    )
    text = f"""# Vela Current Visual Review Pack

This pack contains **{captured_count}/{expected_count} captured visual scenarios**
from the dedicated `{EXPECTED_BUNDLE_IDENTIFIER}` Debug app: {main_count}
main-window scenarios plus {independent_count} independent-surface scenarios.
Start with `contact-sheets/ALL-PAGES.jpg`
or `REVIEW-INDEX.md`, then inspect canonical full-resolution PNGs under `pages/`.

## Provenance

- Capture mode: PID-scoped Accessibility plus app-owned CoreGraphics windows.
- Exact captured executable SHA-256: `{app.executable_sha256}`.
- Git HEAD observed at capture: `{git['head']}`.
- Workspace dirty at capture: `{str(git['dirty']).lower()}` ({git['statusEntryCount']} status entries).
- Capture started: `{provenance['captureStartedAt']}`.
- Capture finished: `{provenance['captureFinishedAt']}`.
- Whole-screen capture used: {str(boundaries['wholeScreenCaptureUsed']).lower()}.

The executable hash is an observed binary binding. The Git data is a workspace
snapshot only; it is not a cryptographic binding between dirty source files and
the built binary.

## Coverage boundary

- Dedicated page/state routes captured: {fixture['capturedDedicatedVisualRouteCount']}/{fixture['dedicatedVisualRouteCount']}.
- Routed page families captured: {fixture['capturedPageCount']}/{fixture['routedPageCount']}.
- Fixture Registry IDs covered by dedicated routes: {fixture['dedicatedVisualRouteCount']}/{fixture['registeredFixtureCount']}.
- Registered pages without dedicated routes: {unrouted_pages}.

This run plans every registered fixture from the checked-in registry. Full fixture
coverage is `{str(fixture['fullFixtureRegistryCoverage']).lower()}` and scenario
completeness is `{str(scenarios['complete']).lower()}`; those values are calculated
from captured scenario IDs. It is not an approved pixel target set, visual-diff
result, or human approval unless the corresponding receipt is present.
{xctest_statement}

## Files

- `contact-sheets/`: one overview sheet plus one sheet per routed page.
- `REVIEW-INDEX.md`: structured links to every canonical screenshot.
- `pages/<page>/<state>/<appearance>/<locale>/`: {captured_count} canonical PNGs.
- `screenshot-manifest.json`: dimensions, paths, hashes, and binary binding.
- `coverage.json`: scenario, route, fixture, provenance, and capture-boundary accounting.
- `CHATGPT-REVIEW-PROMPT.md`: suggested review brief.
"""
    (staging / "README.md").write_text(text, encoding="utf-8")
    (staging / "README.md").chmod(0o644)


def write_review_prompt(
    staging: Path,
    coverage: dict[str, object],
) -> None:
    fixture = coverage["fixtureRouteCoverage"]
    scenarios = coverage["visualScenarioCoverage"]
    assert isinstance(fixture, dict)
    assert isinstance(scenarios, dict)
    prompt = f"""# Suggested ChatGPT visual-review prompt

Review this Vela macOS visual pack page by page. Begin with README.md,
coverage.json, and contact-sheets/ALL-PAGES.jpg, then use the canonical PNGs for
pixel-level evidence.

Please report:

1. Cross-page shell, hierarchy, spacing, typography, color, icon, and control consistency.
2. Problems per page, classified P0/P1/P2/P3 with exact screenshot IDs.
3. Light/Dark, English/Simplified Chinese, and 1040/1280/1600 window regressions.
4. Truncation, overlap, density, affordance, focus, empty/offline-state, and accessibility concerns visible in the images.
5. Menu Bar, Settings, and TUN sheet issues separately from main-window issues.
6. A prioritized implementation plan, distinguishing evidence from subjective preference.

Do not treat these captures as approved targets. The evidence manifest reports
{scenarios['capturedExpectedScenarioCount']}/{scenarios['expectedScenarioCount']}
captured scenarios and {fixture['capturedDedicatedVisualRouteCount']}/
{fixture['registeredFixtureCount']} registered fixture IDs. Treat missing routes,
states, or receipts exactly as reported in `coverage.json`.
"""
    (staging / "CHATGPT-REVIEW-PROMPT.md").write_text(prompt, encoding="utf-8")
    (staging / "CHATGPT-REVIEW-PROMPT.md").chmod(0o644)


def json_bytes(value: object) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
            allow_nan=False,
        )
        + "\n"
    ).encode("utf-8")


def write_selected_archive(
    archive: Path,
    *,
    root_name: str,
    members: list[tuple[str, Path | bytes]],
) -> None:
    if archive.exists() or archive.is_symlink():
        raise DirectCaptureError(f"archive destination unexpectedly exists: {archive}")
    temporary = archive.parent / f".{archive.name}.tmp"
    if temporary.exists() or temporary.is_symlink():
        raise DirectCaptureError(f"archive temporary path unexpectedly exists: {temporary}")
    if not SAFE_PAGE_NAME.fullmatch(root_name.replace("Vela-Visual-Review-", "")):
        raise DirectCaptureError(f"unsafe archive root name: {root_name}")
    normalized: dict[str, Path | bytes] = {}
    for relative, source in members:
        member = Path(relative)
        if member.is_absolute() or ".." in member.parts or relative in normalized:
            raise DirectCaptureError(f"unsafe or duplicate archive member: {relative}")
        normalized[relative] = source
    try:
        with zipfile.ZipFile(
            temporary,
            mode="w",
            compression=zipfile.ZIP_STORED,
        ) as bundle:
            for relative, source in sorted(normalized.items()):
                if isinstance(source, Path):
                    regular_file(source, f"archive source {relative}")
                    payload = source.read_bytes()
                else:
                    payload = source
                info = zipfile.ZipInfo(
                    filename=f"{root_name}/{relative}",
                    date_time=FIXED_ZIP_TIMESTAMP,
                )
                info.create_system = 3
                info.external_attr = (stat.S_IFREG | 0o644) << 16
                info.compress_type = zipfile.ZIP_STORED
                bundle.writestr(info, payload, compress_type=zipfile.ZIP_STORED)
        temporary.chmod(0o644)
        os.replace(temporary, archive)
    except Exception:
        if temporary.exists() and not temporary.is_symlink():
            temporary.unlink()
        raise
    with zipfile.ZipFile(archive) as bundle:
        failed_member = bundle.testzip()
        if failed_member is not None:
            raise DirectCaptureError(
                f"ZIP integrity failed for {archive.name}: {failed_member}"
            )


def write_split_review_archives(
    staging: Path,
    screenshots: list[dict[str, object]],
    manifest: dict[str, object],
) -> Path:
    archive_root = staging / ARCHIVES_DIRECTORY
    archive_root.mkdir(mode=0o755)
    grouped: dict[str, list[dict[str, object]]] = defaultdict(list)
    for screenshot in screenshots:
        grouped[str(screenshot["page"])].append(screenshot)

    page_order = list(dict.fromkeys(
        route.page for route in (*MAIN_ROUTES, *INDEPENDENT_ROUTES)
    ))
    app_build = manifest["appBuild"]
    page_volumes: list[dict[str, object]] = []
    populated_pages = [page for page in page_order if grouped[page]]
    for volume_index, page in enumerate(populated_pages, start=1):
        if not SAFE_PAGE_NAME.fullmatch(page):
            raise DirectCaptureError(f"unsafe page name for split archive: {page}")
        items = sorted(grouped[page], key=lambda item: str(item["id"]))
        if not items:
            raise DirectCaptureError(f"cannot create empty page archive: {page}")
        archive_name = f"Vela-Visual-Review-{volume_index:02d}-{page}.zip"
        archive = archive_root / archive_name
        page_manifest = {
            "schemaVersion": manifest["schemaVersion"],
            "appBuild": app_build,
            "screenshots": items,
        }
        page_prompt = f"""# ChatGPT review prompt: {page}

Review only the `{page}` page family in this Vela macOS visual volume. The
archive contains {len(items)} canonical PNG screenshots plus a page contact
sheet. Compare states, window sizes, Light/Dark appearances, English/Simplified
Chinese localization, and inspector variants where present.

Report P0/P1/P2/P3 findings with exact screenshot IDs, separating observable
evidence from subjective preference. Check hierarchy, spacing, typography,
color, icons, controls, truncation, overlap, density, affordance, focus,
empty/offline states, and accessibility concerns. Do not treat these captures
as approved pixel targets.
""".encode("utf-8")
        page_readme = f"""# Vela Visual Review volume: {page}

This is volume {volume_index:02d} of {len(populated_pages)} and contains all
{len(items)} captured scenarios for the `{page}` page family. Start with
`contact-sheets/{page}.jpg`, then inspect canonical PNGs under `pages/{page}/`.

The full-run provenance and coverage accounting are retained in `coverage.json`.
The filtered `screenshot-manifest.json` contains only screenshots in this volume.
""".encode("utf-8")
        members: list[tuple[str, Path | bytes]] = [
            ("README.md", page_readme),
            ("CHATGPT-REVIEW-PROMPT.md", page_prompt),
            ("coverage.json", staging / "coverage.json"),
            ("screenshot-manifest.json", json_bytes(page_manifest)),
            (f"contact-sheets/{page}.jpg", staging / f"contact-sheets/{page}.jpg"),
        ]
        for item in items:
            relative = str(item["path"])
            members.append((relative, staging / relative))
        write_selected_archive(
            archive,
            root_name=f"Vela-Visual-Review-{page}",
            members=members,
        )
        page_volumes.append(
            {
                "archive": archive_name,
                "page": page,
                "scenarioCount": len(items),
                "bytes": archive.stat().st_size,
                "sha256": sha256(archive),
            }
        )

    volume_manifest = {
        "schemaVersion": 1,
        "overviewArchive": OVERVIEW_ARCHIVE_NAME,
        "pageVolumeCount": len(page_volumes),
        "pageVolumes": page_volumes,
        "totalScenarioCount": len(screenshots),
    }
    write_json(archive_root / "archive-manifest.json", volume_manifest)
    volume_lines = [
        "# Vela split visual-review archives",
        "",
        "Upload `Vela-Visual-Review-00-Overview.zip` first, then upload page",
        "volumes individually as needed. Each page volume is self-contained.",
        "",
        "| Volume | Page | Scenarios | SHA-256 |",
        "| --- | --- | ---: | --- |",
    ]
    for item in page_volumes:
        volume_lines.append(
            f"| `{item['archive']}` | {item['page']} | {item['scenarioCount']} | "
            f"`{item['sha256']}` |"
        )
    volume_lines.append("")
    (archive_root / "README.md").write_text(
        "\n".join(volume_lines), encoding="utf-8"
    )
    (archive_root / "README.md").chmod(0o644)

    overview_members: list[tuple[str, Path | bytes]] = [
        ("README.md", staging / "README.md"),
        ("REVIEW-INDEX.md", staging / "REVIEW-INDEX.md"),
        ("CHATGPT-REVIEW-PROMPT.md", staging / "CHATGPT-REVIEW-PROMPT.md"),
        ("coverage.json", staging / "coverage.json"),
        ("screenshot-manifest.json", staging / "screenshot-manifest.json"),
        ("VOLUME-INDEX.md", archive_root / "README.md"),
        ("archive-manifest.json", archive_root / "archive-manifest.json"),
    ]
    for contact_sheet in sorted((staging / "contact-sheets").glob("*")):
        if contact_sheet.is_file():
            overview_members.append(
                (f"contact-sheets/{contact_sheet.name}", contact_sheet)
            )
    overview = archive_root / OVERVIEW_ARCHIVE_NAME
    write_selected_archive(
        overview,
        root_name="Vela-Visual-Review-Overview",
        members=overview_members,
    )
    return overview


def validate_manifest(staging: Path) -> None:
    regular_file(MANIFEST_VALIDATOR, "screenshot manifest validator")
    run_checked(
        [
            sys.executable,
            str(MANIFEST_VALIDATOR),
            str(staging / "screenshot-manifest.json"),
            "--root",
            str(staging),
        ],
        timeout=120,
    )


def capture_review_pack(
    app_value: Path,
    output_value: Path,
    pages_filter: set[str] | None = None,
) -> Path:
    app = validate_app_bundle(app_value)
    output = validate_output(output_value)
    scenarios = planned_scenarios(pages_filter)
    fixture_ids = load_fixture_ids()
    assert_no_existing_exact_process(app.executable)
    started_at = utc_now()
    git = git_snapshot()

    staging = Path(
        tempfile.mkdtemp(prefix=f".{output.name}.capture-", dir=str(output.parent))
    )
    staging.chmod(0o700)
    work_root = staging / ".capture-work"
    work_root.mkdir(mode=0o700)
    screenshots: list[dict[str, object]] = []
    sources: list[dict[str, object]] = []
    screenshot_ids: set[str] = set()
    caffeinate: subprocess.Popen[bytes] | None = None

    try:
        with tempfile.TemporaryDirectory(prefix="vela-direct-capture-") as helper_tmp:
            helper = compile_helper(Path(helper_tmp))
            trusted = helper_command(helper, ["trusted"], timeout=8)
            if trusted != "trusted":
                raise DirectCaptureError(
                    "visual capture helper did not confirm Accessibility trust"
                )
            caffeinate = subprocess.Popen(
                ["/usr/bin/caffeinate", "-dimsu", "-w", str(os.getpid())],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            for index, scenario in enumerate(scenarios, start=1):
                if index > 1 and (index - 1) % CAPTURE_COOLDOWN_INTERVAL == 0:
                    print(
                        f"  capture cooldown {CAPTURE_COOLDOWN_SECONDS:.0f}s "
                        f"after {index - 1} scenarios",
                        flush=True,
                    )
                    time.sleep(CAPTURE_COOLDOWN_SECONDS)
                print(
                    f"[{index:03d}/{len(scenarios)}] {scenario.expected_id}",
                    flush=True,
                )
                last_error: DirectCaptureError | None = None
                for attempt in range(1, CAPTURE_MAX_ATTEMPTS + 1):
                    try:
                        screenshot, source = capture_one(
                            app,
                            helper,
                            scenario,
                            staging,
                            work_root,
                        )
                        break
                    except DirectCaptureError as error:
                        last_error = error
                        if attempt == CAPTURE_MAX_ATTEMPTS:
                            raise
                        print(
                            f"  retry {attempt + 1}/{CAPTURE_MAX_ATTEMPTS} "
                            "after transient capture error: "
                            f"{str(error).splitlines()[0]}",
                            flush=True,
                        )
                        time.sleep(CAPTURE_RETRY_BASE_DELAY * attempt)
                else:
                    assert last_error is not None
                    raise last_error
                identifier = str(screenshot["id"])
                if identifier in screenshot_ids:
                    raise DirectCaptureError(f"duplicate screenshot ID: {identifier}")
                screenshot_ids.add(identifier)
                screenshots.append(screenshot)
                sources.append(source)

        if work_root.exists() and not work_root.is_symlink():
            shutil.rmtree(work_root)
        screenshots.sort(key=lambda item: str(item["id"]))
        finished_at = utc_now()
        review_boundary = derive_review_boundary(
            staging,
            expected_commit=str(git["head"]),
            expected_executable_sha256=app.executable_sha256,
            workspace_clean=not bool(git["dirty"]),
        )
        coverage = build_coverage(
            app=app,
            screenshots=screenshots,
            sources=sources,
            fixture_ids=fixture_ids,
            started_at=started_at,
            finished_at=finished_at,
            git=git,
            accessibility_trusted=trusted == "trusted",
            review_boundary=review_boundary,
            pages_filter=pages_filter,
        )
        manifest = {
            "schemaVersion": 1,
            "appBuild": f"observed-binary-sha256:{app.executable_sha256}",
            "screenshots": screenshots,
        }
        write_json(staging / "screenshot-manifest.json", manifest)
        write_json(staging / "coverage.json", coverage)
        build_contact_sheets(screenshots, staging)
        write_review_index(screenshots, staging)
        write_readme(staging, app=app, coverage=coverage)
        write_review_prompt(staging, coverage)
        validate_manifest(staging)
        archive = write_split_review_archives(staging, screenshots, manifest)
        archive_relative = archive.relative_to(staging)
        staging.chmod(0o755)
        os.replace(staging, output)
        return output / archive_relative
    except Exception:
        if staging.exists() and not staging.is_symlink() and staging.parent == output.parent:
            shutil.rmtree(staging)
        raise
    finally:
        if caffeinate is not None and caffeinate.poll() is None:
            caffeinate.terminate()
            try:
                caffeinate.wait(timeout=2)
            except subprocess.TimeoutExpired:
                caffeinate.kill()
            caffeinate.wait(timeout=2)


def probe_visual_scenario(
    app_value: Path,
    scenario_id: str,
    output_value: Path | None = None,
    *,
    overview_accessibility_probe: bool = False,
) -> dict[str, object]:
    """Capture and validate one scenario without retaining review artifacts."""
    app = validate_app_bundle(app_value)
    matches = [
        scenario for scenario in planned_scenarios()
        if scenario.expected_id == scenario_id
    ]
    if len(matches) != 1:
        raise DirectCaptureError(f"unknown canonical scenario: {scenario_id}")
    if overview_accessibility_probe and matches[0].page != "overview":
        raise DirectCaptureError(
            "--overview-accessibility-probe requires an Overview scenario"
        )
    probe_output: Path | None = None
    if output_value is not None:
        if not output_value.is_absolute() or output_value.suffix.lower() != ".png":
            raise DirectCaptureError("--probe-output must be an absolute .png path")
        if output_value.exists() or output_value.is_symlink():
            raise DirectCaptureError("--probe-output must not already exist")
        parent = output_value.parent.resolve(strict=True)
        if not parent.is_dir():
            raise DirectCaptureError("--probe-output parent must be a directory")
        probe_output = parent / output_value.name
    assert_no_existing_exact_process(app.executable)
    with tempfile.TemporaryDirectory(prefix="vela-visual-probe-") as staging_value:
        staging = Path(staging_value)
        work_root = staging / ".capture-work"
        work_root.mkdir(mode=0o700)
        with tempfile.TemporaryDirectory(prefix="vela-direct-capture-") as helper_tmp:
            helper = compile_helper(Path(helper_tmp))
            if helper_command(helper, ["trusted"], timeout=8) != "trusted":
                raise DirectCaptureError(
                    "visual capture helper did not confirm Accessibility trust"
                )
            screenshot, source = capture_one(
                app,
                helper,
                matches[0],
                staging,
                work_root,
                overview_accessibility_probe=overview_accessibility_probe,
            )
            if probe_output is not None:
                source_png = regular_file(
                    staging / str(screenshot["path"]),
                    "probe screenshot",
                )
                shutil.copyfile(source_png, probe_output)
                probe_output.chmod(0o644)
            result = {
                "appExecutableSHA256": app.executable_sha256,
                "screenshot": screenshot,
                "source": source,
            }
            if probe_output is not None:
                result["probeOutput"] = str(probe_output)
            if overview_accessibility_probe:
                result["verifiedAccessibilityIdentifiers"] = list(
                    OVERVIEW_ACCESSIBILITY_PROBE_IDENTIFIERS
                )
            return result


def parse_arguments(arguments: Iterable[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Capture Vela's registry-derived visual scenario matrix from the "
            "dedicated Debug visual app and create an organized review ZIP."
        )
    )
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument(
        "--page",
        action="append",
        choices=sorted({route.page for route in (*MAIN_ROUTES, *INDEPENDENT_ROUTES)}),
        help="capture only this page family; repeat to select more than one",
    )
    parser.add_argument(
        "--probe-scenario",
        help="capture and validate one canonical scenario, then discard it",
    )
    parser.add_argument(
        "--probe-output",
        type=Path,
        help="with --probe-scenario, retain the validated PNG at this absent path",
    )
    parser.add_argument(
        "--overview-accessibility-probe",
        action="store_true",
        help=(
            "with an Overview --probe-scenario, enable deterministic Increase "
            "Contrast and Reduce Motion overrides and require its AX identifiers"
        ),
    )
    return parser.parse_args(arguments)


def main(arguments: Iterable[str] | None = None) -> int:
    args = parse_arguments(arguments)
    try:
        if args.probe_output is not None and not args.probe_scenario:
            raise DirectCaptureError("--probe-output requires --probe-scenario")
        if args.overview_accessibility_probe and not args.probe_scenario:
            raise DirectCaptureError(
                "--overview-accessibility-probe requires --probe-scenario"
            )
        if args.probe_scenario:
            result = probe_visual_scenario(
                args.app,
                args.probe_scenario,
                args.probe_output,
                overview_accessibility_probe=args.overview_accessibility_probe,
            )
            print(json.dumps(result, ensure_ascii=False, sort_keys=True))
            return 0
        archive = capture_review_pack(
            args.app,
            args.output_dir,
            set(args.page) if args.page else None,
        )
    except (
        DirectCaptureError,
        ReviewPackError,
        OSError,
        subprocess.SubprocessError,
    ) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"reviewPack={archive.parent}")
    print(f"reviewArchive={archive}")
    print(f"archiveSHA256={hashlib.sha256(archive.read_bytes()).hexdigest()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
