#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import subprocess
import sys
from pathlib import Path, PurePosixPath
from typing import Any

from json_schema import SchemaError, validate


class EvidenceError(RuntimeError):
    pass


def load(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise EvidenceError(f"{path} must contain an object")
    return value


def evidence_path(root: Path, descriptor: dict[str, Any]) -> Path:
    relative = descriptor["path"]
    logical = PurePosixPath(relative)
    if logical.is_absolute() or ".." in logical.parts or not logical.parts:
        raise EvidenceError(f"unsafe evidence path: {relative}")
    candidate = root.joinpath(*logical.parts)
    root_resolved = root.resolve()
    try:
        candidate.relative_to(root)
    except ValueError as error:
        raise EvidenceError(f"evidence path escapes root: {relative}") from error
    if candidate.is_symlink() or not candidate.is_file():
        raise EvidenceError(f"evidence path is not a regular file: {relative}")
    if candidate.resolve().parent != root_resolved and root_resolved not in candidate.resolve().parents:
        raise EvidenceError(f"evidence path resolves outside root: {relative}")
    file_descriptor = os.open(candidate, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        info = os.fstat(file_descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_size != descriptor["size"]:
            raise EvidenceError(f"evidence size/type mismatch: {relative}")
        digest = hashlib.sha256()
        with os.fdopen(file_descriptor, "rb", closefd=False) as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != descriptor["sha256"]:
            raise EvidenceError(f"evidence SHA256 mismatch: {relative}")
    finally:
        os.close(file_descriptor)
    return candidate


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest")
    parser.add_argument("--evidence-root")
    parser.add_argument("--allow-synthetic-urls", action="store_true")
    args = parser.parse_args()
    manifest_path = Path(args.manifest)
    root = Path(args.evidence_root) if args.evidence_root else manifest_path.parent
    try:
        manifest = load(manifest_path)
        schema = load(Path(__file__).resolve().parents[1] / "schemas/test-run-manifest.schema.json")
        validate(manifest, schema)
        if manifest["source"]["dirty"]:
            raise EvidenceError("test evidence source was dirty")
        tests = manifest["tests"]
        if not tests:
            raise EvidenceError("test evidence contains no executed tests")
        incomplete = [item["id"] for item in tests if item["status"] != "passed"]
        if incomplete:
            raise EvidenceError(f"tests are not all passed: {incomplete}")
        cleanup = manifest["cleanup"]
        if cleanup["status"] != "passed":
            raise EvidenceError("cleanup did not pass")
        if cleanup["managedPIDs"] or cleanup["ownedTunInterfaces"]:
            raise EvidenceError("cleanup reports process or TUN residue")
        for key in ("systemProxyMatches", "routeStateMatches", "temporaryResourcesRemoved"):
            if cleanup[key] is not True:
                raise EvidenceError(f"cleanup did not prove {key}")
        referenced: set[Path] = set()
        for test in tests:
            if not test["evidence"]:
                raise EvidenceError(f"test has no evidence: {test['id']}")
            referenced.update(evidence_path(root, value) for value in test["evidence"])
        if not cleanup["evidence"]:
            raise EvidenceError("cleanup has no evidence")
        referenced.update(evidence_path(root, value) for value in cleanup["evidence"])

        command = [
            sys.executable,
            str(Path(__file__).with_name("scan_beta_evidence.py")),
            str(root),
            "--policy",
            str(Path(__file__).resolve().parents[1] / "config/evidence-policy.json"),
        ]
        if args.allow_synthetic_urls:
            command.append("--allow-synthetic-urls")
        result = subprocess.run(command, text=True, capture_output=True)
        if result.returncode != 0:
            raise EvidenceError(result.stderr.strip() or "evidence privacy scan failed")
    except (OSError, KeyError, ValueError, json.JSONDecodeError, SchemaError, EvidenceError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"Test evidence passed with {len(referenced)} referenced file(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
