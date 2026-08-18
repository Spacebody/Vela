#!/usr/bin/env python3
"""Copy V0.7 non-compiled resources while preserving their directory hierarchy."""

from __future__ import annotations

import argparse
import os
import shutil
import stat
import sys
import tempfile
from pathlib import Path, PurePosixPath


class EmbedError(ValueError):
    pass


SOURCE_PREFIX = "$(SRCROOT)/Vela/Resources/"
OUTPUT_PREFIX = "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/"
ALLOWED_ROOTS = {"Help", "Policies", "ReleaseCandidate", "Schemas"}
ALLOWED_SINGLE_FILES = {"Localization/terminology.json"}


def environment(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise EmbedError(f"required Xcode build setting is empty: {name}")
    return value


def read_list(path: Path, label: str) -> list[str]:
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError as error:
        raise EmbedError(f"{label} is missing: {path}") from error
    if stat.S_ISLNK(mode) or not stat.S_ISREG(mode):
        raise EmbedError(f"{label} must be a regular non-symlink file: {path}")
    lines = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        value = raw.strip()
        if value and not value.startswith("#"):
            lines.append(value)
    if not lines or len(lines) != len(set(lines)):
        raise EmbedError(f"{label} must contain a non-empty unique path inventory")
    return lines


def parse_relative(source_entry: str) -> PurePosixPath:
    if not source_entry.startswith(SOURCE_PREFIX):
        raise EmbedError(f"resource input has an unexpected prefix: {source_entry}")
    raw = source_entry.removeprefix(SOURCE_PREFIX)
    relative = PurePosixPath(raw)
    if (
        relative.is_absolute()
        or "\\" in raw
        or any(part in {"", ".", ".."} for part in relative.parts)
    ):
        raise EmbedError(f"resource input is unsafe: {source_entry}")
    if relative.as_posix() not in ALLOWED_SINGLE_FILES and (
        not relative.parts or relative.parts[0] not in ALLOWED_ROOTS
    ):
        raise EmbedError(f"resource input is outside the V0.7 allowlist: {source_entry}")
    if any(part.startswith(".") for part in relative.parts):
        raise EmbedError(f"hidden resource input is forbidden: {source_entry}")
    return relative


def require_regular_file(path: Path, label: str) -> None:
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError as error:
        raise EmbedError(f"{label} is missing: {path}") from error
    if stat.S_ISLNK(mode) or not stat.S_ISREG(mode):
        raise EmbedError(f"{label} must be a regular non-symlink file: {path}")


def require_directory(path: Path, label: str) -> None:
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError as error:
        raise EmbedError(f"{label} is missing: {path}") from error
    if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
        raise EmbedError(f"{label} must be a regular non-symlink directory: {path}")


def ensure_destination_parent(resources: Path, relative: PurePosixPath) -> Path:
    current = resources
    for part in relative.parent.parts:
        current = current / part
        if current.exists() or current.is_symlink():
            mode = current.lstat().st_mode
            if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
                raise EmbedError(f"resource destination contains an unsafe component: {current}")
        else:
            current.mkdir(mode=0o755)
    return resources.joinpath(*relative.parts)


def install_atomic(source: Path, destination: Path, temporary_root: Path) -> None:
    require_regular_file(source, "V0.7 resource")
    if destination.exists() or destination.is_symlink():
        mode = destination.lstat().st_mode
        if stat.S_ISLNK(mode) or not stat.S_ISREG(mode):
            raise EmbedError(f"refusing to replace an unsafe resource output: {destination}")
    descriptor, temporary_name = tempfile.mkstemp(
        prefix="vela-v07-resource.", dir=temporary_root
    )
    temporary = Path(temporary_name)
    try:
        with source.open("rb") as source_handle, os.fdopen(descriptor, "wb") as output_handle:
            shutil.copyfileobj(source_handle, output_handle, 1024 * 1024)
            output_handle.flush()
            os.fsync(output_handle.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, destination)
    finally:
        if temporary.exists():
            temporary.unlink()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-list", required=True)
    parser.add_argument("--output-list", required=True)
    args = parser.parse_args()
    try:
        product_bundle_identifier = environment("PRODUCT_BUNDLE_IDENTIFIER")
        is_visual_test_build = (
            product_bundle_identifier == "dev.yilin.Vela.VisualTests"
            and environment("CONFIGURATION") == "Debug"
            and os.environ.get("VELA_VISUAL_TEST_BUILD", "").strip() == "YES"
        )
        if product_bundle_identifier != "dev.yilin.Vela" and not is_visual_test_build:
            raise EmbedError("V0.7 resources may only be embedded in the Vela App target")
        if environment("FULL_PRODUCT_NAME") != "Vela.app":
            raise EmbedError("FULL_PRODUCT_NAME must be Vela.app")

        source_root = Path(environment("SRCROOT")) / "Vela/Resources"
        target_build_dir = Path(environment("TARGET_BUILD_DIR"))
        resource_setting = PurePosixPath(environment("UNLOCALIZED_RESOURCES_FOLDER_PATH"))
        if resource_setting != PurePosixPath("Vela.app/Contents/Resources"):
            raise EmbedError(
                "UNLOCALIZED_RESOURCES_FOLDER_PATH must be Vela.app/Contents/Resources"
            )
        resources = target_build_dir.joinpath(*resource_setting.parts)
        temporary_root = Path(environment("TARGET_TEMP_DIR"))
        require_directory(source_root, "V0.7 source resource root")
        require_directory(target_build_dir, "TARGET_BUILD_DIR")
        require_directory(temporary_root, "TARGET_TEMP_DIR")
        resources.mkdir(parents=True, exist_ok=True)
        require_directory(resources, "App Resources directory")

        input_entries = read_list(Path(args.input_list), "V0.7 resource input list")
        output_entries = read_list(Path(args.output_list), "V0.7 resource output list")
        relatives = [parse_relative(entry) for entry in input_entries]
        expected_outputs = [OUTPUT_PREFIX + relative.as_posix() for relative in relatives]
        if output_entries != expected_outputs:
            raise EmbedError(
                "V0.7 resource output list must exactly mirror the ordered input inventory"
            )

        for relative in relatives:
            source = source_root.joinpath(*relative.parts)
            destination = ensure_destination_parent(resources, relative)
            install_atomic(source, destination, temporary_root)
        print(f"Embedded {len(relatives)} V0.7 resources with preserved hierarchy.")
        return 0
    except (EmbedError, OSError, UnicodeDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
