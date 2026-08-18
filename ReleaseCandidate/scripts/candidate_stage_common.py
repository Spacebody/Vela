#!/usr/bin/env python3
"""Shared fail-closed helpers for private candidate-stage evidence."""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path, PurePosixPath
from typing import Any
from urllib.parse import unquote, urlparse

from _common import (
    GateError,
    git_output,
    parse_semver,
    reject_forbidden_text,
    valid_commit,
    valid_sha256,
    validate_build_number,
)


JSON_LIMIT = 4 * 1024 * 1024
CHECKSUM_LIMIT = 4 * 1024 * 1024
SPARKLE_VERIFICATION_TOOL_VERSION = "verify_signed_appcast_artifacts.py/1"
SAFE_INVENTORY_PART = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
PLACEHOLDERS = {
    "n/a",
    "na",
    "placeholder",
    "replace",
    "replace me",
    "replace_me",
    "replaceme",
    "tbd",
    "todo",
    "unknown",
}
UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)


def secure_directory(raw: str | Path, *, label: str) -> Path:
    path = Path(raw)
    if not path.is_dir() or path.is_symlink():
        raise GateError(f"{label} must be a regular non-symlink directory: {path}")
    return path.resolve(strict=True)


def secure_private_evidence_root(raw: str | Path, *, label: str) -> Path:
    """Return a canonical, release-user-owned private evidence root.

    Public/candidate roots have different permission contracts, so this is kept
    deliberately separate from ``secure_directory``.  The promotion evidence
    root and its ``private`` child are the trust boundary for unsigned human
    approvals and verification receipts; accepting a shared or other-user-owned
    directory would let a local account replace those records by renaming them.
    """

    root = secure_directory(raw, label=label)
    private = root / "private"
    for path, path_label in ((root, label), (private, f"{label}/private")):
        try:
            metadata = path.lstat()
        except OSError as error:
            raise GateError(f"{path_label} is missing or unsafe: {path}: {error}") from error
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
            raise GateError(f"{path_label} must be a regular non-symlink directory: {path}")
        if metadata.st_uid != os.geteuid():
            raise GateError(f"{path_label} must be owned by the release user: {path}")
        if stat.S_IMODE(metadata.st_mode) != 0o700:
            raise GateError(f"{path_label} permissions must be 0700: {path}")
    if private.resolve(strict=True) != private:
        raise GateError(f"{label}/private contains an unsafe alias: {private}")
    return root


def _normalize_system_alias(root: Path, path: Path) -> Path:
    """Normalize macOS /var and /tmp aliases without resolving evidence symlinks."""

    root_text = str(root)
    path_text = str(path)
    for canonical, alias in (("/private/var", "/var"), ("/private/tmp", "/tmp")):
        if (root_text == canonical or root_text.startswith(f"{canonical}/")) and (
            path_text == alias or path_text.startswith(f"{alias}/")
        ):
            return Path(f"/private{path_text}")
    return path


def _stage_path(root: Path, raw: str | Path, *, label: str) -> tuple[Path, str]:
    supplied = Path(raw)
    if ".." in supplied.parts:
        raise GateError(f"{label} path may not contain '..': {raw}")
    candidate = supplied if supplied.is_absolute() else root / supplied
    candidate = _normalize_system_alias(root, Path(os.path.abspath(candidate)))
    try:
        relative = candidate.relative_to(root)
    except ValueError as error:
        raise GateError(f"{label} escapes the candidate evidence root: {raw}") from error
    if not relative.parts:
        raise GateError(f"{label} must name a file below the candidate evidence root")
    cursor = root
    for index, part in enumerate(relative.parts):
        cursor /= part
        try:
            metadata = cursor.lstat()
        except OSError as error:
            raise GateError(f"{label} is missing: {cursor}: {error}") from error
        if stat.S_ISLNK(metadata.st_mode):
            raise GateError(f"{label} path contains a symlink: {cursor}")
        if index < len(relative.parts) - 1 and not stat.S_ISDIR(metadata.st_mode):
            raise GateError(f"{label} parent is not a directory: {cursor}")
    try:
        resolved = candidate.resolve(strict=True)
    except OSError as error:
        raise GateError(f"{label} cannot be resolved safely: {candidate}: {error}") from error
    if resolved != candidate:
        raise GateError(f"{label} path contains an unsafe alias: {candidate}")
    return candidate, relative.as_posix()


def stage_directory(root: Path, raw: str | Path, *, label: str) -> tuple[Path, str]:
    path, relative = _stage_path(root, raw, label=label)
    if not path.is_dir() or path.is_symlink():
        raise GateError(f"{label} must be a regular non-symlink directory: {path}")
    cursor = root
    for part in PurePosixPath(relative).parts:
        cursor /= part
        metadata = cursor.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            raise GateError(f"{label} path contains a symlink: {cursor}")
        if not stat.S_ISDIR(metadata.st_mode):
            raise GateError(f"{label} contains a non-directory path component: {cursor}")
    return path, relative


def read_stage_file(
    root: Path,
    raw: str | Path,
    *,
    label: str,
    maximum_bytes: int | None = None,
    retain_bytes: bool = True,
) -> tuple[bytes, dict[str, Any]]:
    path, relative = _stage_path(root, raw, label=label)
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode):
        raise GateError(f"{label} must be a regular file: {path}")
    if before.st_size <= 0:
        raise GateError(f"{label} must not be empty: {path}")
    if maximum_bytes is not None and before.st_size > maximum_bytes:
        raise GateError(f"{label} exceeds {maximum_bytes} bytes: {path}")

    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise GateError(f"cannot safely open {label}: {path}: {error}") from error
    digest = hashlib.sha256()
    chunks: list[bytes] = []
    total = 0
    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != (
            before.st_dev,
            before.st_ino,
        ):
            raise GateError(f"{label} changed before it could be read safely")
        if maximum_bytes is not None and opened.st_size > maximum_bytes:
            raise GateError(f"{label} exceeds {maximum_bytes} bytes: {path}")
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
            if retain_bytes:
                chunks.append(chunk)
            total += len(chunk)
            if maximum_bytes is not None and total > maximum_bytes:
                raise GateError(f"{label} exceeds {maximum_bytes} bytes: {path}")
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if (
        (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns)
        != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
        or total != opened.st_size
    ):
        raise GateError(f"{label} changed while it was being read")
    final = path.lstat()
    if (final.st_dev, final.st_ino, final.st_size, final.st_mtime_ns) != (
        after.st_dev,
        after.st_ino,
        after.st_size,
        after.st_mtime_ns,
    ):
        raise GateError(f"{label} changed after it was read")
    data = b"".join(chunks) if retain_bytes else b""
    return data, {
        "path": relative,
        "filename": path.name,
        "size": total,
        "sha256": digest.hexdigest(),
    }


def collect_updates_subjects(
    root: Path,
    raw_directory: str | Path,
    *,
    excluded_file: Path,
) -> tuple[str, list[dict[str, Any]]]:
    """Hash every stable regular file below updates, excluding the inventory itself."""

    directory, relative = stage_directory(root, raw_directory, label="updates root")
    excluded = excluded_file.resolve(strict=True)
    records: list[dict[str, Any]] = []

    def visit(current: Path) -> None:
        before = current.lstat()
        try:
            entries = sorted(os.scandir(current), key=lambda item: item.name)
        except OSError as error:
            raise GateError(f"cannot enumerate updates root safely: {current}: {error}") from error
        fingerprints: list[tuple[str, int, int, int]] = []
        for entry in entries:
            metadata = entry.stat(follow_symlinks=False)
            fingerprints.append((entry.name, metadata.st_dev, metadata.st_ino, metadata.st_mode))
            path = Path(entry.path)
            if stat.S_ISLNK(metadata.st_mode):
                raise GateError(f"updates root contains a symlink: {path}")
            if stat.S_ISDIR(metadata.st_mode):
                visit(path)
            elif stat.S_ISREG(metadata.st_mode):
                if path.resolve(strict=True) == excluded:
                    continue
                _, record = read_stage_file(
                    root,
                    path,
                    label=f"updates subject {path.name}",
                    retain_bytes=False,
                )
                records.append(record)
            else:
                raise GateError(f"updates root contains a non-regular entry: {path}")
        final_entries = sorted(os.scandir(current), key=lambda item: item.name)
        final_fingerprints = [
            (
                entry.name,
                entry.stat(follow_symlinks=False).st_dev,
                entry.stat(follow_symlinks=False).st_ino,
                entry.stat(follow_symlinks=False).st_mode,
            )
            for entry in final_entries
        ]
        after = current.lstat()
        if (
            fingerprints != final_fingerprints
            or (before.st_dev, before.st_ino, before.st_mtime_ns)
            != (after.st_dev, after.st_ino, after.st_mtime_ns)
        ):
            raise GateError(f"updates root changed while it was inventoried: {current}")

    visit(directory)
    records.sort(key=lambda record: record["path"])
    if len(records) < 3:
        raise GateError("updates checksum inventory must cover at least three artifacts")
    if len(records) > 4096:
        raise GateError("updates checksum inventory exceeds 4096 artifacts")
    return relative, records


def validate_updates_checksums(
    data: bytes,
    *,
    updates_root: str,
    subjects: list[dict[str, Any]],
    checksums_record: dict[str, Any],
) -> None:
    if len(data) > CHECKSUM_LIMIT:
        raise GateError("updates checksum inventory exceeds 4 MiB")
    if not data.endswith(b"\n"):
        raise GateError("updates checksum inventory must end with a newline")
    try:
        lines = data.decode("utf-8").splitlines()
    except UnicodeError as error:
        raise GateError("updates checksum inventory must be UTF-8") from error
    if not lines:
        raise GateError("updates checksum inventory is empty")

    root_path = PurePosixPath(updates_root)
    expected: dict[str, dict[str, Any]] = {}
    for record in subjects:
        validate_record(record, label="updates subject")
        try:
            local = PurePosixPath(record["path"]).relative_to(root_path).as_posix()
        except ValueError as error:
            raise GateError("updates subject escapes the declared updates root") from error
        if local in expected:
            raise GateError(f"duplicate updates subject path: {local}")
        expected[local] = record

    inventory_path = PurePosixPath(checksums_record["path"])
    inventory_local: str | None
    try:
        inventory_local = inventory_path.relative_to(root_path).as_posix()
    except ValueError:
        inventory_local = None

    actual: dict[str, str] = {}
    ordered_names: list[str] = []
    for line_number, line in enumerate(lines, 1):
        pieces = line.split("  ", 1)
        raw_name = pieces[1] if len(pieces) == 2 else ""
        path = PurePosixPath(raw_name)
        safe = (
            len(pieces) == 2
            and valid_sha256(pieces[0])
            and "\\" not in raw_name
            and not path.is_absolute()
            and path.as_posix() == raw_name
            and all(
                part not in {"", ".", ".."} and SAFE_INVENTORY_PART.fullmatch(part)
                for part in path.parts
            )
        )
        if not safe:
            raise GateError(f"invalid updates checksum row at line {line_number}")
        if raw_name == inventory_local:
            raise GateError("updates checksum inventory cannot recursively list itself")
        if raw_name in actual:
            raise GateError(f"duplicate updates checksum path: {raw_name}")
        actual[raw_name] = pieces[0]
        ordered_names.append(raw_name)
    if ordered_names != sorted(ordered_names):
        raise GateError("updates checksum rows must be sorted by relative path")
    if set(actual) != set(expected):
        missing = sorted(set(expected) - set(actual))
        extra = sorted(set(actual) - set(expected))
        raise GateError(
            f"updates checksum inventory is incomplete or stale (missing={missing}, extra={extra})"
        )
    for name, record in expected.items():
        if actual[name] != record["sha256"]:
            raise GateError(f"updates checksum differs from exact artifact bytes: {name}")


def require_updates_subject(
    record: dict[str, Any],
    subjects: list[dict[str, Any]],
    *,
    label: str,
) -> None:
    matches = [subject for subject in subjects if subject["path"] == record["path"]]
    if matches != [record]:
        raise GateError(f"complete updates inventory does not bind the exact {label} bytes")


def reject_text_artifact(data: bytes, *, label: str) -> str:
    try:
        value = data.decode("utf-8")
    except UnicodeError as error:
        raise GateError(f"{label} must be UTF-8") from error
    reject_forbidden_text(value, label=label)
    if re.search(r"\b(?:TODO|TBD|REPLACE_ME|PLACEHOLDER)\b", value, re.IGNORECASE):
        raise GateError(f"{label} contains placeholder text")
    return value


def validate_candidate_appcast(
    data: bytes,
    *,
    build: int,
    dmg_filename: str,
    release_notes_filename: str,
) -> None:
    lowered = data.lower()
    if b"<!doctype" in lowered or b"<!entity" in lowered:
        raise GateError("signed appcast contains a forbidden DOCTYPE or ENTITY")
    try:
        document = ET.fromstring(data)
    except ET.ParseError as error:
        raise GateError(f"signed appcast XML is invalid: {error}") from error
    channel = document.find("channel") if document.tag == "rss" else None
    if channel is None:
        raise GateError("signed appcast lacks an RSS channel")
    matches = []
    for item in channel.findall("item"):
        item_build = item.findtext(f"{{{SPARKLE_NS}}}version", default="").strip()
        if item_build == str(build):
            matches.append(item)
    if len(matches) != 1:
        raise GateError("signed appcast must contain exactly one item for the candidate build")
    item = matches[0]
    notes = item.find(f"{{{SPARKLE_NS}}}releaseNotesLink")
    enclosure = item.find("enclosure")
    if notes is None or enclosure is None:
        raise GateError("candidate appcast item lacks release notes or enclosure")
    notes_url = notes.text or notes.attrib.get("url", "")
    dmg_url = enclosure.attrib.get("url", "")
    actual_notes = Path(unquote(urlparse(notes_url).path)).name
    actual_dmg = Path(unquote(urlparse(dmg_url).path)).name
    if actual_notes != release_notes_filename:
        raise GateError("candidate appcast item does not reference the exact signed release notes")
    if actual_dmg != dmg_filename:
        raise GateError("candidate appcast item does not reference the exact DMG")


def validate_sbom(value: dict[str, Any]) -> None:
    if value.get("spdxVersion") != "SPDX-2.3":
        raise GateError("SBOM must declare SPDX-2.3")
    if value.get("SPDXID") != "SPDXRef-DOCUMENT":
        raise GateError("SBOM must identify the SPDX document")
    if not isinstance(value.get("name"), str) or not value["name"].strip():
        raise GateError("SBOM must have a non-empty document name")


def verify_signed_appcast(
    repository: Path,
    *,
    appcast: Path,
    updates_root: Path,
    sign_update: str | Path,
    ed_key_file: str | Path,
    appcast_sha256: str,
) -> dict[str, Any]:
    verifier = repository / "Release/scripts/verify_signed_appcast_artifacts.py"
    if not verifier.is_file() or verifier.is_symlink():
        raise GateError("candidate source lacks the tracked Sparkle artifact verifier")
    result = subprocess.run(
        (
            sys.executable,
            str(verifier),
            str(appcast),
            "--artifacts-dir",
            str(updates_root),
            "--sign-update",
            str(sign_update),
            "--ed-key-file",
            str(ed_key_file),
        ),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=180,
        check=False,
    )
    if result.returncode != 0:
        raise GateError("signed appcast artifact verification failed")
    if re.fullmatch(
        r"Verified [1-9][0-9]* Sparkle artifact signature\(s\) from [1-9][0-9]* feed item\(s\)\.\n?",
        result.stdout,
    ) is None:
        raise GateError("signed appcast verifier returned an unexpected success receipt")
    return {
        "status": "verified",
        "toolVersion": SPARKLE_VERIFICATION_TOOL_VERSION,
        "appcastSHA256": appcast_sha256,
    }


def decode_json(data: bytes, *, label: str) -> dict[str, Any]:
    try:
        value = json.loads(data.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise GateError(f"invalid {label} JSON: {error}") from error
    if not isinstance(value, dict):
        raise GateError(f"{label} must contain a JSON object")
    reject_placeholders(value, label=label)
    return value


def reject_placeholders(value: Any, *, label: str) -> None:
    reject_forbidden_text(value, label=label)

    def visit(candidate: Any) -> None:
        if isinstance(candidate, dict):
            for key, item in candidate.items():
                visit(key)
                visit(item)
        elif isinstance(candidate, list):
            for item in candidate:
                visit(item)
        elif isinstance(candidate, str):
            normalized = re.sub(r"[`*_\"']", "", candidate.strip()).casefold()
            if (
                normalized in PLACEHOLDERS
                or normalized.startswith("replace ")
                or normalized.startswith("replace_")
                or (normalized.startswith("<") and normalized.endswith(">"))
            ):
                raise GateError(f"{label} contains placeholder text")

    visit(value)


def candidate_contract(
    *, version: str, build: int, tag: str, commit: str
) -> tuple[str, str, str | None]:
    base, prerelease = parse_semver(version)
    if prerelease is not None and re.fullmatch(r"rc\.[1-9][0-9]*", prerelease) is None:
        raise GateError("candidate version must be Stable SemVer or rc.N")
    validate_build_number(build)
    if tag != f"v{version}":
        raise GateError("candidate tag must exactly equal v<candidate-version>")
    if not valid_commit(commit):
        raise GateError("candidate commit must be a non-zero full SHA-1")
    label = None if prerelease is None else f"RC {prerelease.split('.', 1)[1]}"
    return base, "stable" if prerelease is None else "beta", label


def verify_repository(root: Path, *, tag: str, commit: str) -> None:
    if git_output(root, "rev-parse", "HEAD") != commit:
        raise GateError("candidate commit differs from repository HEAD")
    tag_ref = f"refs/tags/{tag}"
    if git_output(root, "cat-file", "-t", tag_ref) != "tag":
        raise GateError("candidate tag must be annotated")
    if git_output(root, "rev-parse", f"{tag_ref}^{{commit}}") != commit:
        raise GateError("candidate tag does not resolve to the exact candidate commit")
    if git_output(root, "status", "--porcelain"):
        raise GateError("candidate-stage evidence requires a clean repository")


def notary_summary(value: dict[str, Any], record: dict[str, Any], *, label: str) -> dict[str, Any]:
    identifier = value.get("id")
    if not isinstance(identifier, str) or UUID_RE.fullmatch(identifier) is None:
        raise GateError(f"{label} notary receipt lacks a valid submission UUID")
    if value.get("status") != "Accepted":
        raise GateError(f"{label} notary receipt is not Accepted")
    return {"file": record, "submissionID": identifier, "status": "Accepted"}


def validate_app_receipt(
    value: dict[str, Any],
    *,
    version: str,
    build: int,
    tag: str,
    commit: str,
    architecture_sha256: str,
    dmg_record: dict[str, Any],
    app_archive_record: dict[str, Any],
    appcast_record: dict[str, Any],
    certificate_sha256: str,
    app_notary: dict[str, Any],
    dmg_notary: dict[str, Any],
) -> None:
    base, channel, label = candidate_contract(
        version=version,
        build=build,
        tag=tag,
        commit=commit,
    )
    if value.get("schemaVersion") != 1 or value.get("manifestKind") != "external":
        raise GateError("App receipt must be an external release manifest")
    app = value.get("app")
    if not isinstance(app, dict):
        raise GateError("App receipt lacks app identity")
    expected_app = {
        "version": base,
        "build": build,
        "channel": channel,
        "prereleaseLabel": label,
        "bundleIdentifier": "dev.yilin.Vela",
    }
    for key, expected in expected_app.items():
        if app.get(key) != expected:
            raise GateError(f"App receipt app.{key} differs from the candidate")
    source = value.get("source")
    if not isinstance(source, dict) or source.get("tag") != tag or source.get("commit") != commit:
        raise GateError("App receipt source differs from the candidate")
    if source.get("architectureFreezeSHA256") != architecture_sha256:
        raise GateError("App receipt architecture SHA-256 differs from the candidate")
    build_value = value.get("build")
    if not isinstance(build_value, dict) or build_value.get("sourceDirty") is not False:
        raise GateError("App receipt must record clean source")
    if value.get("appBundle") != {"name": "Vela.app"}:
        raise GateError("App receipt must identify Vela.app")
    trust = value.get("trust")
    if not isinstance(trust, dict) or trust.get("signingCertificateSHA256") != certificate_sha256:
        raise GateError("App receipt signing certificate differs from candidate-stage evidence")
    artifacts = value.get("artifacts")
    if not isinstance(artifacts, dict):
        raise GateError("App receipt lacks external artifact records")
    for key, label, record in (
        ("dmg", "DMG", dmg_record),
        ("appZip", "App archive", app_archive_record),
        ("appcast", "appcast", appcast_record),
    ):
        receipt_record = artifacts.get(key)
        if not isinstance(receipt_record, dict) or any(
            receipt_record.get(field) != record[field]
            for field in ("filename", "size", "sha256")
        ):
            raise GateError(f"App receipt {label} bytes differ from candidate-stage evidence")
    notarization = value.get("notarization")
    if not isinstance(notarization, dict):
        raise GateError("App receipt lacks notarization summaries")
    expected_notary = {
        "app": {"submissionID": app_notary["submissionID"], "status": "Accepted"},
        "dmg": {"submissionID": dmg_notary["submissionID"], "status": "Accepted"},
    }
    if notarization != expected_notary:
        raise GateError("App receipt notarization summaries differ from retained receipts")


def validate_archive_receipt(value: dict[str, Any]) -> None:
    if value.get("schemaVersion") != 3 or value.get("archiveName") != "Vela.xcarchive":
        raise GateError("archive receipt must describe Vela.xcarchive with schemaVersion 3")
    if set(value) != {
        "schemaVersion",
        "archiveName",
        "archiveTree",
        "publicContract",
        "cli",
        "products",
        "records",
    }:
        raise GateError("archive receipt has an unexpected schema")
    archive_tree = value.get("archiveTree")
    if not isinstance(archive_tree, dict) or set(archive_tree) != {
        "fileCount",
        "directoryCount",
        "totalSize",
        "sha256",
    }:
        raise GateError("archive receipt has invalid archive-tree evidence")
    for key in ("fileCount", "directoryCount", "totalSize"):
        count = archive_tree.get(key)
        if isinstance(count, bool) or not isinstance(count, int) or count < 1:
            raise GateError("archive receipt has invalid archive-tree evidence")
    if not valid_sha256(archive_tree.get("sha256")):
        raise GateError("archive receipt has invalid archive-tree evidence")
    contract = value.get("publicContract")
    if (
        not isinstance(contract, dict)
        or set(contract) != {"filename", "size", "sha256"}
        or contract.get("filename") != "public-contract-freeze.json"
        or not isinstance(contract.get("size"), int)
        or contract["size"] <= 0
        or not valid_sha256(contract.get("sha256"))
    ):
        raise GateError("archive receipt has invalid public-contract evidence")
    records = value.get("records")
    if not isinstance(records, list) or not records:
        raise GateError("archive receipt must contain at least one dSYM record")
    record_by_name: dict[str, dict[str, Any]] = {}
    for record in records:
        if not isinstance(record, dict) or set(record) != {
            "name", "dSYM", "DWARF", "size", "sha256", "uuids"
        }:
            raise GateError("archive receipt contains a malformed dSYM record")
        for key in ("name", "dSYM", "DWARF"):
            raw = record.get(key)
            if not isinstance(raw, str) or not raw or Path(raw).is_absolute() or ".." in Path(raw).parts:
                raise GateError(f"archive receipt contains an unsafe {key}")
        if not isinstance(record.get("size"), int) or record["size"] <= 0:
            raise GateError("archive receipt contains an invalid DWARF size")
        if not valid_sha256(record.get("sha256")):
            raise GateError("archive receipt contains an invalid DWARF SHA-256")
        if record["name"] in record_by_name:
            raise GateError("archive receipt contains duplicate dSYM names")
        record_by_name[record["name"]] = record
        uuids = record.get("uuids")
        if not isinstance(uuids, list) or not uuids:
            raise GateError("archive receipt contains no UUID evidence")
        for item in uuids:
            if (
                not isinstance(item, dict)
                or UUID_RE.fullmatch(str(item.get("uuid", ""))) is None
                or not isinstance(item.get("architecture"), str)
                or not item["architecture"]
            ):
                raise GateError("archive receipt contains malformed UUID evidence")
        pairs = [(item["uuid"], item["architecture"]) for item in uuids]
        if len(pairs) != len(set(pairs)):
            raise GateError("archive receipt contains duplicate UUID evidence")

    cli = value.get("cli")
    if cli not in (
        {"contractAvailability": "absent", "artifactPresence": "absent"},
        {"contractAvailability": "present", "artifactPresence": "present"},
    ):
        raise GateError("archive receipt has invalid frozen CLI evidence")
    expected_names = {"Vela", "VelaHelper"}
    if cli["artifactPresence"] == "present":
        expected_names.add("vela")
    elif "vela" in record_by_name:
        raise GateError("archive receipt fabricates CLI symbols while CLI is frozen absent")

    products = value.get("products")
    if not isinstance(products, list) or len(products) != len(expected_names):
        raise GateError("archive receipt has an invalid published-binary inventory")
    product_names: set[str] = set()
    uuid_owners: dict[tuple[str, str], int] = {}
    expected_paths = {
        "Vela": "Products/Applications/Vela.app/Contents/MacOS/Vela",
        "VelaHelper": (
            "Products/Applications/Vela.app/Contents/Library/LaunchServices/VelaHelper"
        ),
        "vela": "Products/Applications/Vela.app/Contents/Helpers/vela",
    }
    for product in products:
        if not isinstance(product, dict) or set(product) != {
            "name", "binary", "size", "sha256", "uuids", "debugSymbols"
        }:
            raise GateError("archive receipt contains a malformed published binary")
        name = product.get("name")
        if name not in expected_names or name in product_names:
            raise GateError("archive receipt published-binary names are invalid")
        product_names.add(name)
        if product.get("binary") != expected_paths[name]:
            raise GateError(f"archive receipt {name} binary path is invalid")
        if not isinstance(product.get("size"), int) or product["size"] <= 0:
            raise GateError(f"archive receipt {name} binary size is invalid")
        if not valid_sha256(product.get("sha256")):
            raise GateError(f"archive receipt {name} binary SHA-256 is invalid")
        debug = product.get("debugSymbols")
        if debug != record_by_name.get(name):
            raise GateError(f"archive receipt {name} does not bind its exact dSYM")
        if product.get("uuids") != debug["uuids"]:
            raise GateError(f"archive receipt {name} UUIDs differ from its dSYM")
        for item in product["uuids"]:
            pair = (item["uuid"], item["architecture"])
            uuid_owners[pair] = uuid_owners.get(pair, 0) + sum(
                pair == (candidate["uuid"], candidate["architecture"])
                for record in records
                for candidate in record["uuids"]
            )
    if product_names != expected_names or any(count != 1 for count in uuid_owners.values()):
        raise GateError("each published Mach-O UUID must have exactly one matching dSYM")


def verify_archive_uuid_binding(
    repository: Path,
    *,
    archive: Path,
    receipt: Path,
    public_contract: Path | None = None,
) -> None:
    verifier = repository / "Release/scripts/inventory_dsyms.py"
    if not verifier.is_file() or verifier.is_symlink():
        raise GateError("candidate source lacks the tracked dSYM UUID verifier")
    command = [
        sys.executable,
        str(verifier),
        "--archive",
        str(archive),
        "--verify-receipt",
        str(receipt),
    ]
    if public_contract is not None:
        command.extend(("--public-contract", str(public_contract)))
    result = subprocess.run(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=180,
        check=False,
    )
    if result.returncode != 0:
        raise GateError("published Mach-O/dSYM UUID binding verification failed")


def validate_record(record: dict[str, Any], *, label: str) -> None:
    raw = record.get("path")
    if not isinstance(raw, str) or "\\" in raw:
        raise GateError(f"{label} path is unsafe")
    pure = PurePosixPath(raw)
    if pure.is_absolute() or ".." in pure.parts or pure.as_posix() != raw:
        raise GateError(f"{label} path is unsafe: {raw}")
    if record.get("filename") != pure.name or Path(pure.name).name != pure.name:
        raise GateError(f"{label} filename does not match its relative path")
    if not isinstance(record.get("size"), int) or record["size"] <= 0:
        raise GateError(f"{label} size is invalid")
    if not valid_sha256(record.get("sha256")):
        raise GateError(f"{label} SHA-256 is invalid")


def all_file_records(value: dict[str, Any]) -> list[tuple[str, dict[str, Any]]]:
    records = [
        ("architecture freeze", value["freeze"]["architecture"]),
        ("DMG", value["artifacts"]["dmg"]),
        ("App archive", value["artifacts"]["appArchive"]),
        ("archive container", value["artifacts"]["archiveContainer"]),
        ("appcast", value["artifacts"]["appcast"]),
        ("SBOM", value["artifacts"]["sbom"]),
        ("signed release notes", value["artifacts"]["signedReleaseNotes"]),
        ("updates checksum inventory", value["artifacts"]["updatesChecksums"]),
        ("App receipt", value["receipts"]["app"]),
        ("archive receipt", value["receipts"]["archive"]),
        ("App notary receipt", value["receipts"]["notarization"]["app"]["file"]),
        ("DMG notary receipt", value["receipts"]["notarization"]["dmg"]["file"]),
    ]
    records.extend(
        (f"updates subject {record['path']}", record)
        for record in value["artifacts"]["updatesSubjects"]
    )
    return records


def verify_record(root: Path, record: dict[str, Any], *, label: str) -> None:
    _, actual = read_stage_file(root, record["path"], label=label)
    if actual != record:
        raise GateError(f"{label} bytes differ from candidate-stage evidence")


def require_private_manifest(path: Path, root: Path | None = None) -> None:
    if not path.is_file() or path.is_symlink():
        raise GateError(f"candidate-stage manifest must be a regular private file: {path}")
    if stat.S_IMODE(path.stat().st_mode) & 0o077:
        raise GateError("candidate-stage manifest must not be group/world accessible")
    if root is not None:
        private_root = (root / "private").resolve(strict=True)
        lexical = _normalize_system_alias(root, Path(os.path.abspath(path)))
        try:
            relative = lexical.relative_to(private_root)
        except ValueError as error:
            raise GateError("candidate-stage manifest must remain under evidence-root/private") from error
        cursor = private_root
        for part in relative.parts:
            cursor /= part
            metadata = cursor.lstat()
            if stat.S_ISLNK(metadata.st_mode):
                raise GateError("candidate-stage manifest path contains a symlink")
        if lexical.resolve(strict=True) != lexical:
            raise GateError("candidate-stage manifest path contains an unsafe alias")


def write_private_json(path: Path, root: Path, value: dict[str, Any]) -> None:
    private_root = root / "private"
    if not private_root.is_dir() or private_root.is_symlink():
        raise GateError("evidence-root/private must be a regular non-symlink directory")
    private_root = private_root.resolve(strict=True)
    lexical_output = _normalize_system_alias(
        root,
        Path(os.path.abspath(path if path.is_absolute() else root / path)),
    )
    if lexical_output.exists() or lexical_output.is_symlink():
        raise GateError(
            f"refusing to overwrite immutable candidate-stage manifest: {lexical_output}"
        )
    if not lexical_output.parent.is_dir() or lexical_output.parent.is_symlink():
        raise GateError("candidate-stage manifest parent is missing or unsafe")
    output = lexical_output
    try:
        output.relative_to(private_root)
    except ValueError as error:
        raise GateError("candidate-stage manifest output must be under evidence-root/private") from error
    cursor = private_root
    for part in output.parent.relative_to(private_root).parts:
        cursor /= part
        metadata = cursor.lstat()
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
            raise GateError("candidate-stage manifest parent is unsafe")
    if output.parent.resolve(strict=True) != output.parent:
        raise GateError("candidate-stage manifest parent contains an unsafe alias")

    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{output.name}.", dir=output.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(value, handle, indent=2, sort_keys=True, ensure_ascii=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        try:
            os.link(temporary, output)
        except FileExistsError as error:
            raise GateError(f"candidate-stage manifest appeared concurrently: {output}") from error
    finally:
        temporary.unlink(missing_ok=True)
