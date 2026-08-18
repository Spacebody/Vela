#!/usr/bin/env python3
"""Safely embed Vela release metadata and bundled legal documents.

Expected Xcode build phase inputs:
  $(VELA_RELEASE_MANIFEST_PATH)
  $(SRCROOT)/Release/THIRD_PARTY_NOTICES.md
  $(SRCROOT)/Release/licenses/Sparkle-2.9.4-LICENSE.txt
  $(SRCROOT)/Release/licenses/Yams-6.2.2-LICENSE.txt

Expected outputs are rooted at:
  $(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)
"""

from __future__ import annotations

import os
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path, PurePosixPath


class EmbedError(ValueError):
    pass


def environment(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise EmbedError(f"required Xcode build setting is empty: {name}")
    return value


def require_regular_file(path: Path, label: str) -> None:
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError as error:
        raise EmbedError(f"{label} is missing: {path}") from error
    if stat.S_ISLNK(mode) or not stat.S_ISREG(mode):
        raise EmbedError(f"{label} must be a regular non-symlink file: {path}")


def ensure_directory_tree(root: Path, relative: PurePosixPath) -> Path:
    current = root
    for part in relative.parts:
        current = current / part
        try:
            mode = current.lstat().st_mode
        except FileNotFoundError:
            current.mkdir(mode=0o755)
            mode = current.lstat().st_mode
        if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
            raise EmbedError(f"release resource destination contains an unsafe component: {current}")
    return current


def copy_atomic(source: Path, destination: Path) -> None:
    require_regular_file(source, "release resource")
    try:
        destination_mode = destination.lstat().st_mode
    except FileNotFoundError:
        destination_mode = None
    if destination_mode is not None and (
        stat.S_ISLNK(destination_mode) or not stat.S_ISREG(destination_mode)
    ):
        raise EmbedError(f"refusing to replace an unsafe release resource: {destination}")
    if source.resolve() == destination.resolve(strict=False):
        raise EmbedError(f"release resource source and destination are identical: {source}")

    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f"vela-{destination.name}.",
        suffix=".tmp",
    )
    temporary = Path(temporary_name)
    source_descriptor: int | None = None
    try:
        source_descriptor = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(source_descriptor, "rb") as source_handle:
            source_descriptor = None
            with os.fdopen(descriptor, "wb") as destination_handle:
                descriptor = -1
                shutil.copyfileobj(source_handle, destination_handle, 1024 * 1024)
                destination_handle.flush()
                os.fsync(destination_handle.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, destination)
        directory_descriptor = os.open(destination.parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        if source_descriptor is not None:
            os.close(source_descriptor)
        if descriptor >= 0:
            os.close(descriptor)
        if temporary.exists():
            temporary.unlink()


def main() -> int:
    try:
        configuration = os.environ.get("CONFIGURATION", "").strip()
        required = os.environ.get("VELA_RELEASE_MANIFEST_REQUIRED", "NO").strip()
        manifest_setting = os.environ.get("VELA_RELEASE_MANIFEST_PATH", "").strip()
        if required not in {"YES", "NO"}:
            raise EmbedError("VELA_RELEASE_MANIFEST_REQUIRED must be YES or NO")
        if configuration != "Release" and (required == "YES" or manifest_setting):
            raise EmbedError("release manifests may only be embedded in Release configuration")
        if required == "NO" and manifest_setting:
            raise EmbedError(
                "VELA_RELEASE_MANIFEST_PATH requires VELA_RELEASE_MANIFEST_REQUIRED=YES"
            )

        manifest: Path | None = None
        if required == "YES":
            manifest = Path(environment("VELA_RELEASE_MANIFEST_PATH"))
            require_regular_file(manifest, "release manifest")
            if manifest.stat().st_size > 1024 * 1024:
                raise EmbedError("release manifest exceeds BuildManifestReader's 1 MiB limit")

        product_bundle_identifier = environment("PRODUCT_BUNDLE_IDENTIFIER")
        is_visual_test_build = (
            product_bundle_identifier == "dev.yilin.Vela.VisualTests"
            and configuration == "Debug"
            and os.environ.get("VELA_VISUAL_TEST_BUILD", "").strip() == "YES"
            and manifest is None
        )
        if product_bundle_identifier != "dev.yilin.Vela" and not is_visual_test_build:
            raise EmbedError("release resources may only be embedded in the Vela App target")
        full_product_name = environment("FULL_PRODUCT_NAME")
        if full_product_name != "Vela.app":
            raise EmbedError("FULL_PRODUCT_NAME must be Vela.app")

        target_build_dir = Path(environment("TARGET_BUILD_DIR"))
        try:
            target_mode = target_build_dir.lstat().st_mode
        except FileNotFoundError as error:
            raise EmbedError("TARGET_BUILD_DIR does not exist") from error
        if stat.S_ISLNK(target_mode) or not stat.S_ISDIR(target_mode):
            raise EmbedError("TARGET_BUILD_DIR must be a regular non-symlink directory")

        resource_setting = environment("UNLOCALIZED_RESOURCES_FOLDER_PATH")
        resource_relative = PurePosixPath(resource_setting)
        expected_relative = PurePosixPath(full_product_name, "Contents", "Resources")
        if (
            resource_relative.is_absolute()
            or any(part in {"", ".", ".."} for part in resource_relative.parts)
            or resource_relative != expected_relative
        ):
            raise EmbedError(
                "UNLOCALIZED_RESOURCES_FOLDER_PATH must be Vela.app/Contents/Resources"
            )
        resources = ensure_directory_tree(target_build_dir, resource_relative)

        script = Path(__file__).resolve()
        repository_root = script.parents[2]
        if manifest is not None:
            verifier = script.with_name("verify_release_manifest.py")
            require_regular_file(verifier, "manifest verifier")
            subprocess.run(
                [sys.executable, str(verifier), str(manifest), "--kind", "bundle"],
                check=True,
            )

        sources_and_destinations = [
            (
                repository_root / "Release/licenses/Sparkle-2.9.4-LICENSE.txt",
                resources / "ThirdParty/Sparkle/LICENSE",
            ),
            (
                repository_root / "Release/licenses/Yams-6.2.2-LICENSE.txt",
                resources / "ThirdParty/Yams/LICENSE",
            ),
            (
                repository_root / "Release/THIRD_PARTY_NOTICES.md",
                resources / "ThirdParty/THIRD_PARTY_NOTICES.md",
            ),
        ]
        if manifest is not None:
            sources_and_destinations.insert(
                0,
                (manifest, resources / "VelaReleaseManifest.json"),
            )
        for _, destination in sources_and_destinations:
            relative_parent = destination.parent.relative_to(resources)
            ensure_directory_tree(resources, PurePosixPath(*relative_parent.parts))
        for source, destination in sources_and_destinations:
            copy_atomic(source, destination)

        if manifest is None:
            print("Embedded bundled third-party legal documents into App Resources.")
        else:
            print("Embedded Vela release manifest and third-party notices into App Resources.")
        return 0
    except (EmbedError, OSError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
