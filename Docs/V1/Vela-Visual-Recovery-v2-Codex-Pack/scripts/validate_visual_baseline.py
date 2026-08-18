#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path

from PIL import Image

from path_safety import (
    PathSafetyError,
    inspect_optional_file,
    resolve_regular_file,
    validate_identifier,
    validate_relative_path,
)
from schema_validation import load_and_validate

ROOT = Path(__file__).resolve().parents[1]


def baseline_failures(data: dict, root: Path, require_approved: bool) -> list[str]:
    target_ids = []
    failures = []

    if require_approved and not data["baselines"]:
        failures.append("manifest contains zero approved visual targets")

    for baseline in data["baselines"]:
        target_id = baseline["targetID"]
        target_ids.append(target_id)
        try:
            validate_identifier(target_id, "targetID")
        except PathSafetyError as error:
            failures.append(str(error))
            continue

        authority = baseline["authority"]
        approval = baseline["approval"]
        approval_status = approval["status"]
        is_approved = authority == "approved" and approval_status == "approved"
        if (authority == "approved") != (approval_status == "approved"):
            failures.append(
                f"{target_id}: authority and approval status must become approved together"
            )
        if authority == "approved" or approval_status == "approved":
            approved_by = approval.get("approvedBy")
            approved_at = approval.get("approvedAt")
            if not isinstance(approved_by, str) or not approved_by.strip():
                failures.append(f"{target_id}: approved target requires approvedBy")
            if not isinstance(approved_at, str) or not approved_at.strip():
                failures.append(f"{target_id}: approved target requires approvedAt")
            thresholds = baseline.get("thresholds")
            if not isinstance(thresholds, dict):
                failures.append(f"{target_id}: approved target requires thresholds")
            else:
                for key in ("structuralChangedPercent", "structuralRMSE"):
                    if key not in thresholds:
                        failures.append(
                            f"{target_id}: approved target threshold missing {key}"
                        )
        if require_approved and not is_approved:
            failures.append(f"{target_id}: target is not approved")

        try:
            validate_relative_path(baseline["targetPath"], f"{target_id} targetPath")
            target = inspect_optional_file(
                root,
                baseline["targetPath"],
                f"{target_id} targetPath",
            )
        except PathSafetyError as error:
            failures.append(str(error))
            target = None
        if is_approved and target is None:
            failures.append(f"{target_id}: approved target file is missing")
        if target is not None:
            actual_sha256 = hashlib.sha256(target.read_bytes()).hexdigest()
            if actual_sha256 != baseline["sha256"]:
                failures.append(
                    f"{target_id} target: manifest SHA-256 "
                    f"{baseline['sha256']} != file SHA-256 {actual_sha256}"
                )
            _validate_image_size(
                target,
                (baseline["width"], baseline["height"]),
                f"{target_id} target",
                failures,
            )

        current_path = baseline.get("currentPath")
        if current_path:
            try:
                validate_relative_path(current_path, f"{target_id} currentPath")
            except PathSafetyError as error:
                failures.append(str(error))

        mask_path = baseline.get("maskPath")
        if mask_path:
            try:
                mask = resolve_regular_file(
                    root,
                    mask_path,
                    f"{target_id} maskPath",
                )
            except PathSafetyError as error:
                failures.append(str(error))
            else:
                _validate_image_size(
                    mask,
                    (baseline["width"], baseline["height"]),
                    f"{target_id} mask",
                    failures,
                )

    if len(target_ids) != len(set(target_ids)):
        failures.append("duplicate targetID")
    return failures


def _validate_image_size(
    path: Path,
    expected: tuple[int, int],
    label: str,
    failures: list[str],
) -> None:
    try:
        with Image.open(path) as image:
            if image.size != expected:
                failures.append(
                    f"{label}: manifest size {expected} != file size {image.size}"
                )
    except OSError as error:
        failures.append(f"{label}: invalid image: {error}")


def load_validated_manifest(path: Path) -> dict:
    return load_and_validate(
        path,
        ROOT / "schemas/visual-baseline-manifest.schema.json",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest")
    parser.add_argument("--root", default=".")
    parser.add_argument("--require-approved", action="store_true")
    args = parser.parse_args()

    data = load_validated_manifest(Path(args.manifest))
    failures = baseline_failures(data, Path(args.root), args.require_approved)
    if failures:
        raise SystemExit("Visual baseline validation failed:\n- " + "\n- ".join(failures))
    print(f"Validated {len(data['baselines'])} visual baseline(s).")


if __name__ == "__main__":
    main()
