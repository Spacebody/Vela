#!/usr/bin/env python3
"""Post-notarization identity for the final Core bundle, outside its own signature."""

from __future__ import annotations

import json
import os
import stat
from pathlib import Path
from typing import Any

from core_release_lib import (
    CoreReleaseError,
    canonical_json_bytes,
    read_regular_bytes,
    sha256_bytes,
    validate_compatibility,
)


MAX_BUNDLE_BYTES = 256 * 1024 * 1024


def build_signed_core_identity(
    bundle: Path,
    compatibility_report: Path,
    upstream_payload: Path,
) -> dict[str, Any]:
    if not bundle.is_dir() or bundle.is_symlink():
        raise CoreReleaseError("signed Core identity requires a regular bundle directory")
    report_raw = read_regular_bytes(compatibility_report, maximum=2 * 1024 * 1024)
    try:
        report = json.loads(report_raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CoreReleaseError(f"compatibility report JSON is invalid: {error}") from error
    validate_compatibility(report)
    artifacts = report.get("artifacts")
    if not isinstance(artifacts, dict) or "upstreamPayloadSHA256" not in artifacts:
        raise CoreReleaseError("compatibility report lacks the unsigned upstream payload identity")
    upstream_raw = read_regular_bytes(upstream_payload, maximum=128 * 1024 * 1024)
    upstream_sha = sha256_bytes(upstream_raw)
    if artifacts["upstreamPayloadSHA256"] != upstream_sha:
        raise CoreReleaseError(
            "compatibility report upstream payload hash differs from retained unsigned bytes"
        )
    if artifacts.get("candidateExecutableSHA256") != upstream_sha:
        raise CoreReleaseError(
            "compatibility candidate is not the retained exact unsigned upstream payload"
        )

    files: list[dict[str, Any]] = []
    total = 0
    resolved_bundle = bundle.resolve(strict=True)
    for path in sorted(bundle.rglob("*"), key=lambda item: item.as_posix()):
        if path.is_symlink():
            raise CoreReleaseError(f"signed Core bundle contains a symlink: {path}")
        if path.is_dir():
            continue
        if not path.is_file():
            raise CoreReleaseError(f"signed Core bundle contains a non-regular file: {path}")
        resolved = path.resolve(strict=True)
        if resolved_bundle not in resolved.parents:
            raise CoreReleaseError("signed Core bundle path escaped its root")
        raw = read_regular_bytes(path, maximum=128 * 1024 * 1024)
        total += len(raw)
        if total > MAX_BUNDLE_BYTES:
            raise CoreReleaseError("signed Core bundle exceeds the identity size limit")
        relative = path.relative_to(bundle).as_posix()
        files.append(
            {
                "mode": f"{stat.S_IMODE(path.stat().st_mode):04o}",
                "relativePath": relative,
                "sha256": sha256_bytes(raw),
                "size": len(raw),
            }
        )
    executable = next(
        (item for item in files if item["relativePath"] == "Contents/MacOS/mihomo"),
        None,
    )
    if executable is None or executable["mode"] != "0755":
        raise CoreReleaseError("signed Core identity lacks the executable 0755 mihomo payload")
    if len(files) != 7:
        raise CoreReleaseError("signed Core identity requires exactly the seven reviewed bundle files")
    return {
        "schemaVersion": 1,
        "coreID": report["coreID"],
        "upstreamPayloadSHA256": upstream_sha,
        "compatibilityReportSHA256": sha256_bytes(report_raw),
        "signedExecutableSHA256": executable["sha256"],
        "bundleFileManifestSHA256": sha256_bytes(canonical_json_bytes(files)),
        "bundleFiles": files,
    }


def validate_signed_core_identity(
    identity_raw: bytes,
    bundle: Path,
    compatibility_report: Path,
    upstream_payload: Path,
) -> dict[str, Any]:
    try:
        identity = json.loads(identity_raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CoreReleaseError(f"signed Core identity JSON is invalid: {error}") from error
    if identity_raw != canonical_json_bytes(identity):
        raise CoreReleaseError("signed Core identity must use canonical JSON bytes")
    expected = build_signed_core_identity(bundle, compatibility_report, upstream_payload)
    if identity != expected:
        raise CoreReleaseError("signed Core identity differs from final post-notarization bundle bytes")
    return identity
