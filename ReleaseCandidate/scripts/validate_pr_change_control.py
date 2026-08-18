#!/usr/bin/env python3
"""Validate required V1 feature-freeze metadata in a pull request body."""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import sys
from pathlib import Path


START_MARKER = "<!-- VELA-FEATURE-FREEZE-CHANGE-CONTROL-START -->"
END_MARKER = "<!-- VELA-FEATURE-FREEZE-CHANGE-CONTROL-END -->"
BODY_LIMIT = 256 * 1024
EVENT_LIMIT = 8 * 1024 * 1024
VALUE_LIMIT = 4 * 1024
REQUIRED_FIELDS = (
    "changeClass",
    "issueID",
    "severity",
    "userImpact",
    "securityImpact",
    "contractImpact",
    "migrationImpact",
    "testEvidence",
    "releaseNoteImpact",
    "reviewer",
)
SEVERITIES = {"critical", "high", "medium", "low", "informational"}
PLACEHOLDERS = {
    "n/a",
    "na",
    "pending",
    "placeholder",
    "replace",
    "replace me",
    "replace_me",
    "replaceme",
    "tbd",
    "todo",
    "unknown",
}
FIELD_LINE = re.compile(r"^([A-Za-z][A-Za-z0-9]*):[ \t]*(.*)$")


class ChangeControlError(ValueError):
    pass


def read_regular_file(path: Path, *, label: str, limit: int) -> bytes:
    """Read a bounded regular file without following a final-component symlink."""

    try:
        before = path.lstat()
    except OSError as error:
        raise ChangeControlError(f"cannot inspect {label}: {path}: {error}") from error
    if not stat.S_ISREG(before.st_mode):
        raise ChangeControlError(f"{label} must be a regular, non-symlink file: {path}")
    if before.st_size > limit:
        raise ChangeControlError(f"{label} exceeds the {limit}-byte limit")

    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise ChangeControlError(f"cannot safely open {label}: {path}: {error}") from error
    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != (
            before.st_dev,
            before.st_ino,
        ):
            raise ChangeControlError(f"{label} changed before it could be read safely")
        chunks: list[bytes] = []
        remaining = limit + 1
        while remaining:
            chunk = os.read(descriptor, min(64 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)

    if len(data) > limit:
        raise ChangeControlError(f"{label} exceeds the {limit}-byte limit")
    if (after.st_size, after.st_mtime_ns) != (opened.st_size, opened.st_mtime_ns):
        raise ChangeControlError(f"{label} changed while it was being read")
    if len(data) != opened.st_size:
        raise ChangeControlError(f"{label} could not be read completely")
    return data


def decode_utf8(data: bytes, *, label: str) -> str:
    try:
        value = data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ChangeControlError(f"{label} must be valid UTF-8") from error
    if "\x00" in value:
        raise ChangeControlError(f"{label} contains a NUL byte")
    return value


def body_from_event(path: Path) -> str:
    raw = read_regular_file(path, label="GitHub event", limit=EVENT_LIMIT)
    try:
        event = json.loads(decode_utf8(raw, label="GitHub event"))
    except json.JSONDecodeError as error:
        raise ChangeControlError(f"GitHub event is not valid JSON: {error}") from error
    if not isinstance(event, dict):
        raise ChangeControlError("GitHub event must be a JSON object")
    pull_request = event.get("pull_request")
    if not isinstance(pull_request, dict):
        raise ChangeControlError("GitHub event does not contain a pull_request object")
    body = pull_request.get("body")
    if not isinstance(body, str):
        raise ChangeControlError("pull_request.body must be a non-null string")
    if len(body.encode("utf-8")) > BODY_LIMIT:
        raise ChangeControlError(f"pull_request.body exceeds the {BODY_LIMIT}-byte limit")
    return body


def normalize_placeholder(value: str) -> str:
    return re.sub(r"[`*_\"']", "", value.strip()).casefold()


def validate_value(field: str, value: str) -> None:
    if not value.strip():
        raise ChangeControlError(f"{field} must not be empty")
    if len(value.encode("utf-8")) > VALUE_LIMIT:
        raise ChangeControlError(f"{field} exceeds the {VALUE_LIMIT}-byte limit")
    if any(ord(character) < 0x20 and character != "\t" for character in value):
        raise ChangeControlError(f"{field} contains a control character")
    normalized = normalize_placeholder(value)
    if (
        normalized in PLACEHOLDERS
        or normalized.startswith("replace_")
        or normalized.startswith("replace ")
        or "<!--" in value
        or "-->" in value
        or (normalized.startswith("<") and normalized.endswith(">"))
    ):
        raise ChangeControlError(f"{field} still contains a placeholder")


def load_allowed_change_classes(path: Path) -> set[str]:
    raw = read_regular_file(path, label="feature-freeze policy", limit=64 * 1024)
    try:
        value = json.loads(decode_utf8(raw, label="feature-freeze policy"))
    except json.JSONDecodeError as error:
        raise ChangeControlError(f"feature-freeze policy is not valid JSON: {error}") from error
    if not isinstance(value, dict):
        raise ChangeControlError("feature-freeze policy must be a JSON object")
    required = value.get("requiredChangeMetadata")
    if required != list(REQUIRED_FIELDS):
        raise ChangeControlError("feature-freeze requiredChangeMetadata does not match the PR gate")
    allowed = value.get("allowedChangeClasses")
    if (
        not isinstance(allowed, list)
        or not allowed
        or any(not isinstance(item, str) or not item for item in allowed)
        or len(allowed) != len(set(allowed))
    ):
        raise ChangeControlError("feature-freeze allowedChangeClasses is invalid")
    return set(allowed)


def parse_metadata(body: str) -> dict[str, str]:
    if body.count(START_MARKER) != 1 or body.count(END_MARKER) != 1:
        raise ChangeControlError("PR body must contain exactly one change-control marker pair")
    start = body.index(START_MARKER) + len(START_MARKER)
    end = body.index(END_MARKER)
    if end <= start:
        raise ChangeControlError("change-control markers are out of order")
    block = body[start:end].strip()
    lines = block.splitlines()
    if len(lines) < 2 or lines[0].strip() != "```yaml" or lines[-1].strip() != "```":
        raise ChangeControlError("change-control metadata must be one fenced yaml block")

    metadata: dict[str, str] = {}
    for raw_line in lines[1:-1]:
        line = raw_line.strip()
        if not line:
            continue
        match = FIELD_LINE.fullmatch(line)
        if match is None:
            raise ChangeControlError(f"invalid change-control line: {line}")
        field, value = match.groups()
        if field not in REQUIRED_FIELDS:
            raise ChangeControlError(f"unexpected change-control field: {field}")
        if field in metadata:
            raise ChangeControlError(f"duplicate change-control field: {field}")
        validate_value(field, value)
        metadata[field] = value.strip()

    missing = [field for field in REQUIRED_FIELDS if field not in metadata]
    if missing:
        raise ChangeControlError(f"missing change-control field(s): {', '.join(missing)}")

    for field in REQUIRED_FIELDS:
        occurrences = re.findall(rf"(?m)^\s*{re.escape(field)}\s*:", body)
        if len(occurrences) != 1:
            raise ChangeControlError(f"{field} must appear exactly once in the PR body")
    return metadata


def validate(body: str, *, allowed_change_classes: set[str]) -> dict[str, str]:
    metadata = parse_metadata(body)
    if metadata["changeClass"] not in allowed_change_classes:
        allowed = ", ".join(sorted(allowed_change_classes))
        raise ChangeControlError(f"changeClass is not allowed; expected one of: {allowed}")
    if metadata["severity"] not in SEVERITIES:
        raise ChangeControlError(
            "severity is not allowed; expected one of: " + ", ".join(sorted(SEVERITIES))
        )
    return metadata


def main() -> int:
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser()
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--body-file")
    source.add_argument("--event-file")
    parser.add_argument(
        "--feature-freeze",
        default=str(root / "ReleaseCandidate/config/feature-freeze.json"),
    )
    args = parser.parse_args()
    try:
        if args.body_file:
            body = decode_utf8(
                read_regular_file(Path(args.body_file), label="PR body", limit=BODY_LIMIT),
                label="PR body",
            )
        else:
            event_path = args.event_file or os.environ.get("GITHUB_EVENT_PATH")
            if not event_path:
                raise ChangeControlError(
                    "GITHUB_EVENT_PATH is required unless --body-file or --event-file is supplied"
                )
            body = body_from_event(Path(event_path))
        allowed = load_allowed_change_classes(Path(args.feature_freeze))
        metadata = validate(body, allowed_change_classes=allowed)
    except (ChangeControlError, OSError, UnicodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(
        "PR feature-freeze change control passed: "
        f"{metadata['changeClass']} / {metadata['severity']} / {metadata['issueID']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
