#!/usr/bin/env python3
"""Create and validate a bounded private Core release evidence archive."""

from __future__ import annotations

import json
import os
import stat
import subprocess
import tempfile
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any

from core_release_lib import (
    CoreReleaseError,
    atomic_write,
    canonical_json_bytes,
    load_json,
    read_regular_bytes,
    sha256_bytes,
)


MAX_FILE_BYTES = 256 * 1024 * 1024
MAX_ARCHIVE_INPUT_BYTES = 768 * 1024 * 1024
MANIFEST_NAME = "private-release-manifest.json"


def _command_output(arguments: list[str]) -> str:
    try:
        result = subprocess.run(
            arguments,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=30,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise CoreReleaseError(
            f"release evidence command failed: {arguments[0]}: {error}"
        ) from error
    return result.stdout.strip()[:16_384]


def _collect_tree(
    source: Path,
    prefix: str,
    entries: dict[str, tuple[bytes, int, str]],
) -> None:
    if not source.is_dir() or source.is_symlink():
        raise CoreReleaseError(f"release evidence source directory is unsafe: {source}")
    for path in sorted(source.rglob("*"), key=lambda item: item.as_posix()):
        if path.is_symlink():
            raise CoreReleaseError(f"release evidence source contains a symlink: {path}")
        if path.is_dir():
            continue
        if not path.is_file():
            raise CoreReleaseError(f"release evidence source is not regular: {path}")
        relative = path.relative_to(source).as_posix()
        _add_file(entries, f"{prefix}/{relative}", path, role=prefix)


def _add_file(
    entries: dict[str, tuple[bytes, int, str]],
    archive_path: str,
    source: Path,
    *,
    role: str,
) -> None:
    pure = PurePosixPath(archive_path)
    if pure.is_absolute() or ".." in pure.parts or archive_path in entries:
        raise CoreReleaseError(f"release evidence archive path is unsafe: {archive_path}")
    raw = read_regular_bytes(source, maximum=MAX_FILE_BYTES)
    mode = stat.S_IMODE(source.stat().st_mode)
    entries[archive_path] = (raw, mode, role)


def _require_paths(entries: dict[str, tuple[bytes, int, str]], required: set[str]) -> None:
    missing = sorted(required - set(entries))
    if missing:
        raise CoreReleaseError(
            "private release evidence is incomplete: " + ", ".join(missing)
        )


def create_evidence_archive(
    *,
    repository_root: Path,
    config_path: Path,
    public_directory: Path,
    prepared_directory: Path | None,
    prior_catalog: Path | None,
    archive_output: Path,
    manifest_output: Path,
) -> dict[str, Any]:
    if archive_output.exists() or archive_output.is_symlink():
        raise CoreReleaseError("private evidence archive output must be a new path")
    if manifest_output.exists() or manifest_output.is_symlink():
        raise CoreReleaseError("private evidence manifest output must be a new path")
    root = repository_root.resolve(strict=True)
    config = load_json(config_path, maximum=256 * 1024)
    operation = config.get("catalog", {}).get("operation")
    if operation not in {"full", "incident"}:
        raise CoreReleaseError("private evidence config operation is invalid")

    entries: dict[str, tuple[bytes, int, str]] = {}
    _add_file(entries, "reviewed/core-release.json", config_path, role="reviewed-config")
    core = config["core"]
    reviewed_paths = {
        "upstream-seed.json": core.get("seed"),
        "LICENSE": core.get("license"),
        "compatibility-report.json": core.get("compatibilityReport"),
        "dedicated-host-evidence.json": core.get("dedicatedHostEvidence"),
        "performance-review.json": core.get("performanceReview"),
        "catalog-public-keyring.json": config["catalog"].get("publicKeyring"),
    }
    for name, relative in reviewed_paths.items():
        if relative is None:
            continue
        source = (root / relative).resolve(strict=True)
        if root not in source.parents:
            raise CoreReleaseError("reviewed evidence path escaped the repository")
        _add_file(entries, f"reviewed/{name}", source, role="reviewed-input")

    _collect_tree(public_directory, "public", entries)
    if prepared_directory is not None:
        _collect_tree(prepared_directory, "prepared", entries)
    if prior_catalog is not None:
        _add_file(entries, "prior/core-catalog.json", prior_catalog, role="prior-catalog")

    machine = {
        "schemaVersion": 1,
        "gitCommit": _command_output(["/usr/bin/git", "-C", str(root), "rev-parse", "HEAD"]),
        "uname": _command_output(["/usr/bin/uname", "-a"]),
        "swVers": _command_output(["/usr/bin/sw_vers"]),
        "xcodebuild": _command_output(["/usr/bin/xcodebuild", "-version"]),
        "codesignPath": _command_output(["/usr/bin/xcrun", "--find", "codesign"]),
        "notarytool": _command_output(["/usr/bin/xcrun", "notarytool", "--version"]),
    }
    machine_raw = canonical_json_bytes(machine)
    entries["release-machine.json"] = (machine_raw, 0o600, "release-machine")

    base_required = {
        "reviewed/core-release.json",
        "reviewed/upstream-seed.json",
        "reviewed/LICENSE",
        "public/core-catalog.json",
        "public/core-catalog.signatures.json",
        "release-machine.json",
    }
    sequence = config["catalog"]["sequence"]
    if not isinstance(sequence, int) or sequence < 1:
        raise CoreReleaseError("private evidence requires a configured Catalog sequence")
    base_required |= {
        f"public/catalog-history/sequence-{sequence}/core-catalog.json",
        f"public/catalog-history/sequence-{sequence}/core-catalog.signatures.json",
    }
    if sequence > 1:
        base_required.add("prior/core-catalog.json")
    if operation == "full":
        if prepared_directory is None:
            raise CoreReleaseError("full Core release evidence requires prepared private staging")
        asset_name = load_json(root / core["seed"], maximum=64 * 1024)["assetName"]
        base_required |= {
            "reviewed/compatibility-report.json",
            "reviewed/dedicated-host-evidence.json",
            "reviewed/performance-review.json",
            f"prepared/upstream/{asset_name}",
            "prepared/upstream/mihomo",
            "prepared/VelaMihomoCore.bundle/Contents/MacOS/mihomo",
            "prepared/notary/notary-core-result.json",
            "prepared/notary/notary-core-log.json",
            f"prepared/notary/VelaMihomoCore-{core['coreID']}.zip",
            "prepared/signed-core-identity.json",
            "public/files.json",
            "public/core-sbom.spdx.json",
        }
    elif prepared_directory is not None:
        raise CoreReleaseError("catalog-only incident evidence must not contain rebuilt Core staging")
    _require_paths(entries, base_required)

    total = sum(len(item[0]) for item in entries.values())
    if total > MAX_ARCHIVE_INPUT_BYTES:
        raise CoreReleaseError("private release evidence exceeds the bounded archive size")
    manifest_files = [
        {
            "path": path,
            "role": role,
            "mode": f"{mode:04o}",
            "size": len(raw),
            "sha256": sha256_bytes(raw),
        }
        for path, (raw, mode, role) in sorted(entries.items())
    ]
    manifest = {
        "schemaVersion": 1,
        "operation": operation,
        "coreID": core["coreID"],
        "catalogSequence": sequence,
        "generatedAt": config["catalog"]["generatedAt"],
        "gitCommit": machine["gitCommit"],
        "files": manifest_files,
    }
    manifest_raw = canonical_json_bytes(manifest)
    atomic_write(manifest_output, manifest_raw, mode=0o600)

    archive_output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{archive_output.name}.", dir=archive_output.parent
    )
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        with zipfile.ZipFile(
            temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9
        ) as archive:
            for path, (raw, mode, _) in sorted(entries.items()):
                info = zipfile.ZipInfo(path, date_time=(2026, 1, 1, 0, 0, 0))
                info.create_system = 3
                info.external_attr = (mode & 0xFFFF) << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, raw)
            info = zipfile.ZipInfo(MANIFEST_NAME, date_time=(2026, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o600 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, manifest_raw)
        os.chmod(temporary, 0o600)
        os.link(temporary, archive_output)
    finally:
        temporary.unlink(missing_ok=True)
    return manifest


def validate_evidence_archive(archive_path: Path, manifest_path: Path) -> dict[str, Any]:
    manifest_raw = read_regular_bytes(manifest_path, maximum=8 * 1024 * 1024)
    try:
        manifest = json.loads(manifest_raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CoreReleaseError(f"private evidence manifest JSON is invalid: {error}") from error
    if manifest_raw != canonical_json_bytes(manifest):
        raise CoreReleaseError("private evidence manifest must use canonical JSON bytes")
    if not isinstance(manifest, dict) or set(manifest) != {
        "schemaVersion", "operation", "coreID", "catalogSequence", "generatedAt",
        "gitCommit", "files",
    } or manifest["schemaVersion"] != 1:
        raise CoreReleaseError("private evidence manifest schema is invalid")
    expected = {item["path"]: item for item in manifest["files"]}
    if len(expected) != len(manifest["files"]):
        raise CoreReleaseError("private evidence manifest paths are duplicated")
    with zipfile.ZipFile(archive_path, "r") as archive:
        names = archive.namelist()
        if len(names) != len(set(names)) or set(names) != set(expected) | {MANIFEST_NAME}:
            raise CoreReleaseError("private evidence archive entries differ from its manifest")
        if archive.read(MANIFEST_NAME) != manifest_raw:
            raise CoreReleaseError("private evidence archive manifest bytes differ from sidecar")
        for name, item in expected.items():
            pure = PurePosixPath(name)
            if pure.is_absolute() or ".." in pure.parts:
                raise CoreReleaseError("private evidence archive contains an unsafe path")
            raw = archive.read(name)
            if len(raw) != item["size"] or sha256_bytes(raw) != item["sha256"]:
                raise CoreReleaseError(f"private evidence archive hash/size mismatch: {name}")
    return manifest
