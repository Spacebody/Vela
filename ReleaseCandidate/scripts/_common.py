#!/usr/bin/env python3
"""Shared fail-closed helpers for Vela release-candidate tooling."""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path
from typing import Any


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SCHEMA_ROOT = Path(__file__).resolve().parents[1] / "schemas"
HARDENING_SCRIPTS = REPOSITORY_ROOT / "Hardening" / "scripts"
if str(HARDENING_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(HARDENING_SCRIPTS))

from json_schema import SchemaError, validate  # noqa: E402


SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
SEMVER_RE = re.compile(
    r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:-((?:0|[1-9A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9A-Za-z-][0-9A-Za-z-]*))*))?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
)
FORBIDDEN_TEXT = (
    "REPLACE_WITH",
    "__PIN_FULL_SHA__",
    "BEGIN PRIVATE KEY",
    "Authorization: Bearer",
)


class GateError(ValueError):
    pass


def require_regular(path: Path, *, label: str = "file", maximum_bytes: int | None = None) -> Path:
    if not path.is_file() or path.is_symlink():
        raise GateError(f"{label} must be a regular non-symlink file: {path}")
    if maximum_bytes is not None and path.stat().st_size > maximum_bytes:
        raise GateError(f"{label} exceeds {maximum_bytes} bytes: {path}")
    return path


def load_json(path: Path, *, label: str = "JSON") -> dict[str, Any]:
    require_regular(path, label=label, maximum_bytes=4 * 1024 * 1024)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise GateError(f"invalid {label}: {path}: {error}") from error
    if not isinstance(value, dict):
        raise GateError(f"{label} must contain a JSON object: {path}")
    return value


def validate_schema(value: dict[str, Any], schema_name: str) -> None:
    schema = load_json(SCHEMA_ROOT / schema_name, label="schema")
    try:
        validate(value, schema)
    except SchemaError as error:
        raise GateError(f"{schema_name} validation failed: {error}") from error


def sha256(path: Path) -> str:
    require_regular(path, label="evidence")
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def valid_sha256(value: Any) -> bool:
    return isinstance(value, str) and SHA256_RE.fullmatch(value) is not None and value != "0" * 64


def valid_commit(value: Any) -> bool:
    return isinstance(value, str) and COMMIT_RE.fullmatch(value) is not None and value != "0" * 40


def parse_semver(value: str) -> tuple[str, str | None]:
    match = SEMVER_RE.fullmatch(value)
    if match is None:
        raise GateError(f"invalid SemVer: {value}")
    base = ".".join(match.group(index) for index in range(1, 4))
    return base, match.group(4)


def validate_build_number(value: int) -> None:
    raw = str(value)
    if re.fullmatch(r"20[0-9]{8}", raw) is None:
        raise GateError("build must use the 10-digit YYYYMMDDNN strategy")
    try:
        datetime.strptime(raw[:8], "%Y%m%d")
    except ValueError as error:
        raise GateError("build contains an invalid YYYYMMDD date") from error
    if raw[8:] == "00":
        raise GateError("build sequence NN must be 01 through 99")


def checked_evidence(root: Path, raw_path: str, expected_sha: str) -> Path:
    if not valid_sha256(expected_sha):
        raise GateError(f"evidence SHA-256 is missing or invalid: {raw_path}")
    candidate = Path(raw_path)
    if candidate.is_absolute() or ".." in candidate.parts:
        raise GateError(f"evidence path must be repository-relative: {raw_path}")
    root = root.resolve()
    path = (root / candidate).resolve()
    try:
        path.relative_to(root)
    except ValueError as error:
        raise GateError(f"evidence escapes repository root: {raw_path}") from error
    require_regular(path, label="evidence")
    actual = sha256(path)
    if actual != expected_sha:
        raise GateError(f"evidence SHA-256 mismatch: {raw_path}")
    return path


def reject_forbidden_text(value: Any, *, label: str) -> None:
    serialized = json.dumps(value, ensure_ascii=False, sort_keys=True)
    for marker in FORBIDDEN_TEXT:
        if marker.lower() in serialized.lower():
            raise GateError(f"{label} contains forbidden marker: {marker}")
    if re.search(r"/(?:Users|private/var/folders)/[^/\s]+", serialized):
        raise GateError(f"{label} contains a machine-local path")
    if re.search(r"\b(?:login|system)\.keychain(?:-db)?\b", serialized, re.IGNORECASE):
        raise GateError(f"{label} contains a Keychain name")


def git_output(root: Path, *arguments: str) -> str:
    try:
        return subprocess.check_output(
            ("git", "-C", str(root), *arguments),
            text=True,
            stderr=subprocess.STDOUT,
        ).strip()
    except subprocess.CalledProcessError as error:
        message = error.output.strip() or "git command failed"
        raise GateError(message) from error


def write_immutable_json(path: Path, value: dict[str, Any]) -> None:
    if path.exists() or path.is_symlink():
        raise GateError(f"refusing to overwrite immutable output: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.parent.is_dir() or path.parent.is_symlink():
        raise GateError(f"immutable output parent is missing or unsafe: {path.parent}")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(value, handle, indent=2, sort_keys=True, ensure_ascii=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o644)
        try:
            os.link(temporary, path)
        except FileExistsError as error:
            raise GateError(f"output appeared concurrently: {path}") from error
    finally:
        temporary.unlink(missing_ok=True)


def main_error(error: Exception) -> int:
    print(f"error: {error}", file=sys.stderr)
    return 1
