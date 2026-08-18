#!/usr/bin/env python3
"""Create and recheck a stable snapshot for GitHub attestation verification."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import tempfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath

from _common import GateError, load_json, main_error, valid_sha256, validate_schema, write_immutable_json


SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")
BUNDLE_LIMIT = 32 * 1024 * 1024


def stable_bytes(path: Path) -> tuple[bytes, dict[str, int]]:
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError as error:
        raise GateError(f"unable to open a non-symlink input: {path}: {error}") from error
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise GateError(f"attestation input is not a regular file: {path}")
        chunks: list[bytes] = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    fingerprint = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
    if fingerprint != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
        raise GateError(f"attestation input changed while it was read: {path}")
    data = b"".join(chunks)
    if len(data) != before.st_size:
        raise GateError(f"attestation input size changed while it was read: {path}")
    return data, {
        "device": before.st_dev,
        "inode": before.st_ino,
        "size": before.st_size,
        "mtimeNS": before.st_mtime_ns,
    }


def stable_digest(path: Path) -> tuple[str, int, dict[str, int]]:
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError as error:
        raise GateError(f"unable to open a non-symlink input: {path}: {error}") from error
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise GateError(f"attestation input is not a regular file: {path}")
        value = hashlib.sha256()
        size = 0
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            value.update(chunk)
            size += len(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    fingerprint = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
    if fingerprint != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) or size != before.st_size:
        raise GateError(f"attestation input changed while it was hashed: {path}")
    return value.hexdigest(), size, {
        "device": before.st_dev,
        "inode": before.st_ino,
        "size": before.st_size,
        "mtimeNS": before.st_mtime_ns,
    }


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_private_bytes(path: Path, data: bytes, *, label: str) -> None:
    if not data:
        raise GateError(f"{label} must not be empty")
    if path.exists() or path.is_symlink():
        raise GateError(f"refusing to overwrite immutable {label}: {path}")
    if not path.parent.is_dir() or path.parent.is_symlink():
        raise GateError(f"{label} parent is missing or unsafe: {path.parent}")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        try:
            os.link(temporary, path)
        except FileExistsError as error:
            raise GateError(f"{label} appeared concurrently: {path}") from error
    finally:
        temporary.unlink(missing_ok=True)


def jsonl_record_for_bytes(
    data: bytes,
    *,
    filename: str,
    label: str,
) -> dict[str, str | int]:
    if SAFE_NAME.fullmatch(filename) is None:
        raise GateError(f"{label} filename is unsafe")
    if len(data) > BUNDLE_LIMIT:
        raise GateError(f"{label} exceeds 32 MiB")
    lines = data.splitlines()
    if not lines:
        raise GateError(f"{label} is empty")
    for line_number, line in enumerate(lines, 1):
        try:
            value = json.loads(line)
        except (UnicodeError, json.JSONDecodeError) as error:
            raise GateError(
                f"{label} has invalid JSON at line {line_number}"
            ) from error
        if not isinstance(value, dict) or not value:
            raise GateError(f"{label} line {line_number} is not a JSON object")
    return {"filename": filename, "sha256": digest(data), "size": len(data)}


def jsonl_record(path: Path, *, label: str) -> dict[str, str | int]:
    data, _ = stable_bytes(path)
    return jsonl_record_for_bytes(data, filename=path.name, label=label)


def bundle_record(path: Path) -> dict[str, str | int]:
    return jsonl_record(path, label="attestation bundle")


def trusted_root_record(path: Path) -> dict[str, str | int]:
    return jsonl_record(path, label="GitHub attestation trusted root")


def seal_file(args: argparse.Namespace) -> None:
    source = Path(args.input)
    label = (
        "attestation bundle"
        if args.kind == "bundle"
        else "GitHub attestation trusted root"
    )
    data, _ = stable_bytes(source)
    # Validate the source before making the caller-visible immutable copy.
    jsonl_record_for_bytes(data, filename=source.name, label=label)
    write_private_bytes(Path(args.output), data, label=label)


def snapshot_file(args: argparse.Namespace) -> None:
    original = Path(args.input)
    snapshot = Path(args.output)
    label = (
        "attestation bundle"
        if args.kind == "bundle"
        else "GitHub attestation trusted root"
    )
    actual_digest, size, _ = copy_snapshot(original, snapshot)
    record = jsonl_record(snapshot, label=label)
    if record["sha256"] != actual_digest or record["size"] != size:
        raise GateError(f"{label} changed while its immutable snapshot was validated")
    if args.expected_sha256 and actual_digest != args.expected_sha256:
        raise GateError(f"{label} SHA-256 differs from the canonical binding")


def check_file(args: argparse.Namespace) -> None:
    original = Path(args.input)
    snapshot = Path(args.snapshot)
    label = (
        "attestation bundle"
        if args.kind == "bundle"
        else "GitHub attestation trusted root"
    )
    original_data, _ = stable_bytes(original)
    snapshot_data, _ = stable_bytes(snapshot)
    original_record = jsonl_record_for_bytes(
        original_data,
        filename=original.name,
        label=label,
    )
    snapshot_record = jsonl_record_for_bytes(
        snapshot_data,
        filename=snapshot.name,
        label=label,
    )
    if original_data != snapshot_data or original_record != {
        **snapshot_record,
        "filename": original.name,
    }:
        raise GateError(f"original {label} changed after its immutable snapshot")
    if args.expected_sha256 and original_record["sha256"] != args.expected_sha256:
        raise GateError(f"{label} SHA-256 differs from the canonical binding")


def seal_bundle(args: argparse.Namespace) -> None:
    canonical_bundles: dict[bytes, None] = {}
    for raw_path in args.verified_result:
        data, _ = stable_bytes(Path(raw_path))
        if len(data) > BUNDLE_LIMIT:
            raise GateError(f"GitHub verification result exceeds 32 MiB: {raw_path}")
        try:
            value = json.loads(data)
        except (UnicodeError, json.JSONDecodeError) as error:
            raise GateError(f"invalid GitHub verification result: {raw_path}") from error
        if not isinstance(value, list) or not value:
            raise GateError(f"GitHub verification result is empty: {raw_path}")
        for item in value:
            attestation = item.get("attestation") if isinstance(item, dict) else None
            if not isinstance(attestation, dict) or not attestation:
                raise GateError(
                    f"GitHub verification result lacks a signed attestation bundle: {raw_path}"
                )
            encoded = json.dumps(
                attestation,
                ensure_ascii=False,
                separators=(",", ":"),
                sort_keys=True,
            ).encode("utf-8")
            canonical_bundles[encoded] = None
    if not canonical_bundles:
        raise GateError("GitHub verification produced no signed attestation bundles")
    output = b"\n".join(sorted(canonical_bundles)) + b"\n"
    if len(output) > BUNDLE_LIMIT:
        raise GateError("sealed attestation bundle exceeds 32 MiB")
    write_private_bytes(Path(args.output), output, label="attestation bundle")


def parse_checksums(data: bytes, checksum_name: str) -> list[tuple[str, str]]:
    if len(data) > 4 * 1024 * 1024:
        raise GateError("subject checksum inventory exceeds 4 MiB")
    try:
        lines = data.decode("utf-8").splitlines()
    except UnicodeError as error:
        raise GateError("subject checksum inventory must be UTF-8") from error
    rows: list[tuple[str, str]] = []
    names: set[str] = set()
    for line_number, line in enumerate(lines, 1):
        pieces = line.split("  ", 1)
        relative = PurePosixPath(pieces[1]) if len(pieces) == 2 else None
        safe_relative = (
            relative is not None
            and not relative.is_absolute()
            and str(relative) == pieces[1]
            and all(part not in {"", ".", ".."} and SAFE_NAME.fullmatch(part) for part in relative.parts)
        )
        if len(pieces) != 2 or not valid_sha256(pieces[0]) or not safe_relative:
            raise GateError(f"invalid subject checksum row at line {line_number}")
        if pieces[1] == checksum_name:
            raise GateError("subject checksum inventory cannot recursively list itself")
        if pieces[1] in names:
            raise GateError(f"duplicate subject checksum filename: {pieces[1]}")
        names.add(pieces[1])
        rows.append((pieces[1], pieces[0]))
    if len(rows) < 3:
        raise GateError("subject checksum inventory is incomplete")
    if len(rows) > 4096:
        raise GateError("subject checksum inventory exceeds 4096 rows")
    return rows


def copy_snapshot(source: Path, path: Path) -> tuple[str, int, dict[str, int]]:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        source_descriptor = os.open(source, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError as error:
        raise GateError(f"unable to open a non-symlink input: {source}: {error}") from error
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o400)
    except OSError:
        os.close(source_descriptor)
        raise
    try:
        before = os.fstat(source_descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise GateError(f"attestation input is not a regular file: {source}")
        value = hashlib.sha256()
        size = 0
        while True:
            chunk = os.read(source_descriptor, 1024 * 1024)
            if not chunk:
                break
            value.update(chunk)
            size += len(chunk)
            view = memoryview(chunk)
            while view:
                written = os.write(descriptor, view)
                if written <= 0:
                    raise GateError(f"failed to write attestation snapshot: {path}")
                view = view[written:]
        after = os.fstat(source_descriptor)
        os.fsync(descriptor)
    finally:
        os.close(source_descriptor)
        os.close(descriptor)
    fingerprint = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
    if fingerprint != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) or size != before.st_size:
        raise GateError(f"attestation input changed while it was snapshotted: {source}")
    return value.hexdigest(), size, {
        "device": before.st_dev,
        "inode": before.st_ino,
        "size": before.st_size,
        "mtimeNS": before.st_mtime_ns,
    }


def create(args: argparse.Namespace) -> None:
    manifest_path = Path(args.manifest).resolve()
    artifacts = Path(args.artifacts_dir).resolve()
    checksums_path = Path(args.subject_checksums).resolve()
    snapshot_dir = Path(args.snapshot_dir)
    inventory_path = Path(args.inventory)
    if not artifacts.is_dir() or artifacts.is_symlink():
        raise GateError("artifacts directory is missing or unsafe")
    for candidate in artifacts.rglob("*"):
        if candidate.is_symlink():
            raise GateError(f"artifacts directory contains a symlink: {candidate}")
    snapshot_dir.mkdir(mode=0o700)

    manifest_data, manifest_stat = stable_bytes(manifest_path)
    if len(manifest_data) > 4 * 1024 * 1024:
        raise GateError("RC manifest exceeds 4 MiB")
    try:
        manifest = json.loads(manifest_data)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise GateError(f"invalid RC manifest snapshot: {error}") from error
    if not isinstance(manifest, dict):
        raise GateError("RC manifest snapshot must be an object")
    checksums_data, checksums_stat = stable_bytes(checksums_path)
    rows = parse_checksums(checksums_data, checksums_path.name)
    checksums_snapshot = snapshot_dir / ".inventory" / checksums_path.name
    checksum_snapshot_digest, checksum_snapshot_size, _ = copy_snapshot(
        checksums_path, checksums_snapshot
    )
    if checksum_snapshot_digest != digest(checksums_data) or checksum_snapshot_size != len(checksums_data):
        raise GateError("subject checksum inventory changed while it was snapshotted")

    records = list(manifest.get("freeze", {}).values()) + list(manifest.get("artifacts", {}).values())
    required_names = {manifest_path.name}
    for record in records:
        if not isinstance(record, dict) or not isinstance(record.get("filename"), str):
            raise GateError("RC manifest contains an invalid file record")
        required_names.add(record["filename"])
    row_names = {name for name, _ in rows}
    missing = required_names - row_names
    if missing:
        raise GateError(f"subject checksum inventory omits public RC records: {sorted(missing)}")

    originals: dict[str, dict] = {}
    subjects: list[dict] = []
    for name, expected_digest in rows:
        source = (artifacts / name).resolve()
        try:
            source.relative_to(artifacts)
        except ValueError as error:
            raise GateError(f"subject checksum path escapes artifacts directory: {name}") from error
        if source == checksums_path:
            raise GateError("subject checksum inventory cannot recursively list itself")
        snapshot = snapshot_dir / name
        actual_digest, source_size, source_stat = copy_snapshot(source, snapshot)
        if actual_digest != expected_digest:
            raise GateError(f"subject checksum mismatch: {name}")
        if name == manifest_path.name and (
            actual_digest != digest(manifest_data) or source_size != len(manifest_data)
        ):
            raise GateError("manifest argument differs from the checksummed manifest subject")
        subjects.append({
            "filename": name,
            "sha256": actual_digest,
            "size": source_size,
            "snapshotPath": str(snapshot.resolve()),
            "originalPath": str(source.resolve()),
        })
        originals[str(source.resolve())] = {
            "path": str(source.resolve()),
            "sha256": actual_digest,
            "size": source_size,
            "stat": source_stat,
        }

    originals[str(manifest_path)] = {
        "path": str(manifest_path),
        "sha256": digest(manifest_data),
        "size": len(manifest_data),
        "stat": manifest_stat,
    }
    originals[str(checksums_path)] = {
        "path": str(checksums_path),
        "sha256": digest(checksums_data),
        "size": len(checksums_data),
        "stat": checksums_stat,
    }
    inventory = {
        "manifestSnapshot": str((snapshot_dir / manifest_path.name).resolve()),
        "subjectChecksums": {
            "filename": checksums_path.name,
            "sha256": digest(checksums_data),
            "size": len(checksums_data),
            "snapshotPath": str(checksums_snapshot.resolve()),
            "originalPath": str(checksums_path),
        },
        "subjects": subjects,
        "originals": list(originals.values()),
    }
    write_immutable_json(inventory_path, inventory)


def check(args: argparse.Namespace) -> None:
    inventory = load_json(Path(args.inventory), label="attestation snapshot inventory")
    errors: list[str] = []
    subjects = inventory["subjects"]
    originals = inventory["originals"]
    if args.subject:
        subjects = [subject for subject in subjects if subject["filename"] == args.subject]
        if len(subjects) != 1:
            raise GateError(f"snapshot inventory has no exact subject: {args.subject}")
        original_path = subjects[0]["originalPath"]
        originals = [item for item in originals if item["path"] == original_path]
        if len(originals) != 1:
            raise GateError(f"snapshot inventory has no exact original: {args.subject}")
    for item in originals:
        path = Path(item["path"])
        try:
            current_digest, current_size, current_stat = stable_digest(path)
        except GateError as error:
            errors.append(str(error))
            continue
        if current_digest != item["sha256"] or current_size != item["size"] or current_stat != item["stat"]:
            errors.append(f"original attestation input changed after snapshot: {path}")
    for subject in subjects:
        try:
            current_digest, current_size, _ = stable_digest(Path(subject["snapshotPath"]))
        except GateError as error:
            errors.append(str(error))
            continue
        if current_digest != subject["sha256"] or current_size != subject["size"]:
            errors.append(f"attestation snapshot changed during verification: {subject['filename']}")
    if not args.subject:
        checksums = inventory["subjectChecksums"]
        try:
            current_digest, current_size, _ = stable_digest(Path(checksums["snapshotPath"]))
        except GateError as error:
            errors.append(str(error))
        else:
            if current_digest != checksums["sha256"] or current_size != checksums["size"]:
                errors.append("subject checksum snapshot changed during verification")
    if errors:
        raise GateError("attestation snapshot consistency failed:\n- " + "\n- ".join(errors))


def report(args: argparse.Namespace) -> None:
    inventory = load_json(Path(args.inventory), label="attestation snapshot inventory")
    bundle = bundle_record(Path(args.bundle))
    trusted_root = trusted_root_record(Path(args.trusted_root))
    for record, supplied_name, label in (
        (bundle, args.bundle_name, "attestation bundle"),
        (trusted_root, args.trusted_root_name, "GitHub attestation trusted root"),
    ):
        if supplied_name:
            if SAFE_NAME.fullmatch(supplied_name) is None:
                raise GateError(f"{label} report filename is unsafe")
            record["filename"] = supplied_name
    value = {
        "schemaVersion": 1,
        "repository": "Spacebody/Vela",
        "signerWorkflow": "github.com/Spacebody/Vela/.github/workflows/release.yml",
        "source": {"commit": args.commit, "ref": f"refs/tags/{args.tag}"},
        "bundle": bundle,
        "trustedRoot": trusted_root,
        "subjectChecksums": {
            key: inventory["subjectChecksums"][key]
            for key in ("filename", "sha256", "size")
        },
        "subjects": [
            {key: subject[key] for key in ("filename", "sha256", "size")}
            for subject in inventory["subjects"]
        ],
        "verifiedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "result": "verifiedByGitHubCLIWithOfflineBundle",
    }
    validate_schema(value, "attestation-verification.schema.json")
    encoded = (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode(
        "utf-8"
    )
    write_private_bytes(Path(args.output), encoded, label="attestation verification report")


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    create_parser = subparsers.add_parser("create")
    create_parser.add_argument("--manifest", required=True)
    create_parser.add_argument("--artifacts-dir", required=True)
    create_parser.add_argument("--subject-checksums", required=True)
    create_parser.add_argument("--snapshot-dir", required=True)
    create_parser.add_argument("--inventory", required=True)
    check_parser = subparsers.add_parser("check")
    check_parser.add_argument("--inventory", required=True)
    check_parser.add_argument("--subject")
    bundle_parser = subparsers.add_parser("bundle")
    bundle_parser.add_argument("--verified-result", action="append", required=True)
    bundle_parser.add_argument("--output", required=True)
    seal_file_parser = subparsers.add_parser("seal-file")
    seal_file_parser.add_argument("--input", required=True)
    seal_file_parser.add_argument("--output", required=True)
    seal_file_parser.add_argument("--kind", choices=("bundle", "trusted-root"), required=True)
    snapshot_file_parser = subparsers.add_parser("snapshot-file")
    snapshot_file_parser.add_argument("--input", required=True)
    snapshot_file_parser.add_argument("--output", required=True)
    snapshot_file_parser.add_argument("--kind", choices=("bundle", "trusted-root"), required=True)
    snapshot_file_parser.add_argument("--expected-sha256")
    check_file_parser = subparsers.add_parser("check-file")
    check_file_parser.add_argument("--input", required=True)
    check_file_parser.add_argument("--snapshot", required=True)
    check_file_parser.add_argument("--kind", choices=("bundle", "trusted-root"), required=True)
    check_file_parser.add_argument("--expected-sha256")
    report_parser = subparsers.add_parser("report")
    report_parser.add_argument("--inventory", required=True)
    report_parser.add_argument("--commit", required=True)
    report_parser.add_argument("--tag", required=True)
    report_parser.add_argument("--bundle", required=True)
    report_parser.add_argument("--bundle-name")
    report_parser.add_argument("--trusted-root", required=True)
    report_parser.add_argument("--trusted-root-name")
    report_parser.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        if args.command == "create":
            create(args)
        elif args.command == "check":
            check(args)
        elif args.command == "bundle":
            seal_bundle(args)
        elif args.command == "seal-file":
            seal_file(args)
        elif args.command == "snapshot-file":
            snapshot_file(args)
        elif args.command == "check-file":
            check_file(args)
        else:
            report(args)
        return 0
    except (GateError, OSError, KeyError, TypeError, ValueError) as error:
        return main_error(error)


if __name__ == "__main__":
    raise SystemExit(main())
