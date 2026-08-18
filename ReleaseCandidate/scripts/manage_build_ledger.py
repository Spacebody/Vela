#!/usr/bin/env python3
"""Atomically reserve and finalize protected Vela build allocations."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import stat
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from _common import GateError, load_json, main_error, valid_sha256
from validate_semver_build import validate_published


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def protected_ledger(raw_path: str) -> Path:
    raw = Path(raw_path)
    if not raw.is_file() or raw.is_symlink():
        raise GateError("protected build ledger must be a regular non-symlink file")
    path = raw.resolve()
    info = path.stat()
    if info.st_uid != os.getuid():
        raise GateError("protected build ledger must be owned by the release user")
    if stat.S_IMODE(info.st_mode) != 0o600:
        raise GateError("protected build ledger permissions must be 0600")
    return path


def open_lock(path: Path) -> int:
    flags = os.O_CREAT | os.O_RDWR
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags, 0o600)
    info = os.fstat(descriptor)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
        os.close(descriptor)
        raise GateError("build-ledger lock is unsafe")
    os.fchmod(descriptor, 0o600)
    fcntl.flock(descriptor, fcntl.LOCK_EX)
    return descriptor


def write_atomic(path: Path, value: dict) -> None:
    validate_published(value)
    payload = (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb", closefd=True) as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except Exception:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def validate_new_candidate(
    *, ledger: Path, version: str, build: int, channel: str, marketing_version: str | None
) -> None:
    command = [
        sys.executable,
        str(Path(__file__).with_name("validate_semver_build.py")),
        "--version",
        version,
        "--build",
        str(build),
        "--channel",
        channel,
        "--published",
        str(ledger),
    ]
    if marketing_version is not None:
        command.extend(("--marketing-version", marketing_version))
    result = subprocess.run(command, text=True, capture_output=True)
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "SemVer/build validation failed"
        raise GateError(detail.removeprefix("error: "))


def reserve(args: argparse.Namespace, ledger: Path) -> None:
    validate_new_candidate(
        ledger=ledger,
        version=args.version,
        build=args.build,
        channel=args.channel,
        marketing_version=args.marketing_version,
    )
    value = load_json(ledger, label="protected build ledger")
    validate_published(value)
    timestamp = utc_now()
    value["builds"].append(
        {
            "version": args.version,
            "build": args.build,
            "channel": args.channel,
            "status": "allocated",
            "artifactSHA256": None,
            "recordedAt": timestamp,
            "statusUpdatedAt": timestamp,
        }
    )
    value["lastReviewedAt"] = timestamp[:10]
    write_atomic(ledger, value)
    print(f"reserved build {args.build} for {args.version}")


def finalize(args: argparse.Namespace, ledger: Path) -> None:
    if args.status in {"published", "withdrawn"} and not valid_sha256(args.artifact_sha256):
        raise GateError(f"{args.status} transition requires a nonzero artifact SHA-256")
    if args.artifact_sha256 is not None and not valid_sha256(args.artifact_sha256):
        raise GateError("artifact SHA-256 is invalid")
    value = load_json(ledger, label="protected build ledger")
    validate_published(value)
    matches = [item for item in value["builds"] if item["build"] == args.build]
    if len(matches) != 1:
        raise GateError("finalization requires exactly one matching build allocation")
    item = matches[0]
    if item["version"] != args.version or item["channel"] != args.channel:
        raise GateError("build allocation identity differs from finalization request")
    if item["status"] == args.status and item["artifactSHA256"] == args.artifact_sha256:
        print(f"build {args.build} was already finalized as {args.status}")
        return
    if item["status"] == "published" and args.status == "withdrawn":
        if args.artifact_sha256 != item["artifactSHA256"]:
            raise GateError("withdrawal must preserve the exact published artifact SHA-256")
        item["status"] = "withdrawn"
        timestamp = utc_now()
        item["statusUpdatedAt"] = timestamp
        value["lastReviewedAt"] = timestamp[:10]
        write_atomic(ledger, value)
        print(f"finalized build {args.build} as withdrawn")
        return
    if item["status"] != "allocated":
        raise GateError(f"build allocation cannot transition from {item['status']} to {args.status}")
    item["status"] = args.status
    item["artifactSHA256"] = args.artifact_sha256
    timestamp = utc_now()
    item["statusUpdatedAt"] = timestamp
    value["lastReviewedAt"] = timestamp[:10]
    write_atomic(ledger, value)
    print(f"finalized build {args.build} as {args.status}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ledger", required=True)
    subparsers = parser.add_subparsers(dest="command", required=True)
    reserve_parser = subparsers.add_parser("reserve")
    reserve_parser.add_argument("--version", required=True)
    reserve_parser.add_argument("--marketing-version")
    reserve_parser.add_argument("--build", type=int, required=True)
    reserve_parser.add_argument("--channel", choices=("rc", "stable"), required=True)
    finalize_parser = subparsers.add_parser("finalize")
    finalize_parser.add_argument("--version", required=True)
    finalize_parser.add_argument("--build", type=int, required=True)
    finalize_parser.add_argument("--channel", choices=("rc", "stable"), required=True)
    finalize_parser.add_argument("--status", choices=("failed", "withdrawn", "published"), required=True)
    finalize_parser.add_argument("--artifact-sha256")
    args = parser.parse_args()
    try:
        ledger = protected_ledger(args.ledger)
        lock_path = ledger.with_name(f".{ledger.name}.lock")
        lock_fd = open_lock(lock_path)
        try:
            if args.command == "reserve":
                reserve(args, ledger)
            else:
                finalize(args, ledger)
        finally:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
            os.close(lock_fd)
        return 0
    except (GateError, OSError, KeyError, TypeError, ValueError) as error:
        return main_error(error)


if __name__ == "__main__":
    raise SystemExit(main())
