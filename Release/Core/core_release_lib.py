#!/usr/bin/env python3
"""Shared, dependency-free policy helpers for the Vela signed Core release."""

from __future__ import annotations

import hashlib
import ipaddress
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


MAX_CATALOG_BYTES = 2 * 1024 * 1024
MAX_SIGNATURE_BYTES = 64 * 1024
MAX_ENTRIES = 100
MAX_FILES = 16
MAX_URL_LENGTH = 2048
MAX_STRING_LENGTH = 4096

ROLE_PATHS = {
    "infoPlist": "Contents/Info.plist",
    "executable": "Contents/MacOS/mihomo",
    "codeResources": "Contents/_CodeSignature/CodeResources",
    "license": "Contents/Resources/LICENSE",
    "notice": "Contents/Resources/NOTICE.md",
    "source": "Contents/Resources/source.json",
    "compatibility": "Contents/Resources/compatibility.json",
}
ROLE_MODES = {role: "0755" if role == "executable" else "0644" for role in ROLE_PATHS}
CATALOG_STATUSES = {"recommended", "available", "blocked", "withdrawn"}
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
CORE_ID_PATTERN = re.compile(r"v([0-9]+\.[0-9]+\.[0-9]+)-r([1-9][0-9]*)")


class CoreReleaseError(ValueError):
    pass


def fail(message: str) -> None:
    raise CoreReleaseError(message)


def read_regular_bytes(path: Path, *, maximum: int | None = None) -> bytes:
    if not path.is_file() or path.is_symlink():
        fail(f"expected a regular non-symlink file: {path}")
    size = path.stat().st_size
    if maximum is not None and size > maximum:
        fail(f"file exceeds {maximum} bytes: {path}")
    return path.read_bytes()


def load_json(path: Path, *, maximum: int | None = None) -> dict[str, Any]:
    try:
        value = json.loads(read_regular_bytes(path, maximum=maximum))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"invalid JSON {path}: {error}")
    if not isinstance(value, dict):
        fail(f"expected a JSON object: {path}")
    return value


def canonical_json_bytes(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def atomic_write(path: Path, data: bytes, *, mode: int = 0o644) -> None:
    if path.exists() or path.is_symlink():
        fail(f"refusing to overwrite immutable output: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.parent.is_symlink():
        fail(f"output parent must not be a symlink: {path.parent}")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        try:
            os.link(temporary, path)
        except FileExistsError as error:
            fail(f"output appeared concurrently: {path}")
    finally:
        temporary.unlink(missing_ok=True)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_time(value: Any, label: str) -> datetime:
    if not isinstance(value, str) or len(value) > 64:
        fail(f"{label} must be an RFC3339 string")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        fail(f"{label} is not valid RFC3339")
    if parsed.tzinfo is None:
        fail(f"{label} must include a timezone")
    return parsed.astimezone(timezone.utc)


def validate_https_url(value: Any, label: str, *, github_download: bool = False) -> str:
    if not isinstance(value, str) or not value or len(value) > MAX_URL_LENGTH:
        fail(f"{label} must be a non-empty URL no longer than {MAX_URL_LENGTH} bytes")
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password or parsed.fragment:
        fail(f"{label} must be a credential-free HTTPS URL")
    if "latest" in [part.lower() for part in parsed.path.split("/")]:
        fail(f"{label} may not use a latest endpoint")
    if github_download and parsed.netloc != "github.com":
        fail(f"{label} must use github.com")
    return value


def production_https_url_issue(value: str) -> str | None:
    """Return why an otherwise-valid HTTPS URL is not a public production endpoint."""
    parsed = urlparse(value)
    hostname = parsed.hostname
    if hostname is None:
        return "missing hostname"
    if hostname.endswith("."):
        return "trailing-dot hostname is not allowed"
    try:
        ascii_hostname = hostname.encode("idna").decode("ascii").lower()
    except UnicodeError:
        return "hostname is not valid IDNA"
    if any(ord(character) <= 0x20 or ord(character) == 0x7F for character in value):
        return "URL contains whitespace or control characters"
    if "__" in value or "$(" in value:
        return "URL contains a build/test placeholder"

    try:
        address = ipaddress.ip_address(ascii_hostname)
    except ValueError:
        address = None
    if address is not None:
        if not address.is_global:
            return "IP endpoint is loopback, private, link-local, reserved, or otherwise non-public"
        return None

    reserved_suffixes = (
        "invalid",
        "test",
        "example",
        "localhost",
        "local",
        "internal",
        "home.arpa",
    )
    labels = ascii_hostname.split(".")
    if len(labels) < 2:
        return "single-label hostname is not public"
    if any(not label for label in labels):
        return "hostname contains an empty label"
    if any(
        not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
        for label in labels
    ):
        return "hostname contains an invalid DNS label"
    if any(
        ascii_hostname == suffix or ascii_hostname.endswith(f".{suffix}")
        for suffix in reserved_suffixes
    ):
        return "hostname uses a reserved or local-only namespace"
    if any(
        ascii_hostname == domain or ascii_hostname.endswith(f".{domain}")
        for domain in ("example.com", "example.net", "example.org")
    ):
        return "hostname uses a reserved example domain"
    return None


def validate_production_https_url(value: Any, label: str) -> str:
    url = validate_https_url(value, label)
    issue = production_https_url_issue(url)
    if issue is not None:
        fail(f"{label} is not a public production HTTPS endpoint: {issue}")
    return url


def validate_seed(seed: dict[str, Any]) -> dict[str, Any]:
    expected_keys = {
        "schemaVersion", "version", "tag", "commit", "assetName", "assetURL",
        "archiveSHA256", "archiveSizeBytes", "sourceURL", "licenseURL",
    }
    if set(seed) != expected_keys:
        fail(f"upstream seed fields differ from the fixed schema: {sorted(set(seed) ^ expected_keys)}")
    if seed["schemaVersion"] != 1:
        fail("unsupported upstream seed schema")
    version = seed["version"]
    if not isinstance(version, str) or re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", version) is None:
        fail("upstream version must be an exact vX.Y.Z tag")
    if seed["tag"] != version:
        fail("upstream tag must exactly equal version")
    if re.fullmatch(r"[0-9a-f]{7,40}", str(seed["commit"])) is None:
        fail("upstream commit must be a reviewed hexadecimal commit")
    expected_asset = f"mihomo-darwin-arm64-{version}.gz"
    if seed["assetName"] != expected_asset:
        fail(f"upstream asset must be exactly {expected_asset}")
    asset_url = validate_https_url(seed["assetURL"], "assetURL", github_download=True)
    expected_url = f"https://github.com/MetaCubeX/mihomo/releases/download/{version}/{expected_asset}"
    if asset_url != expected_url:
        fail("assetURL is not the immutable exact-tag Mihomo arm64 asset URL")
    if SHA256_PATTERN.fullmatch(str(seed["archiveSHA256"])) is None:
        fail("archiveSHA256 must be lowercase SHA-256")
    if not isinstance(seed["archiveSizeBytes"], int) or seed["archiveSizeBytes"] <= 0:
        fail("archiveSizeBytes must be a positive integer")
    expected_source = f"https://github.com/MetaCubeX/mihomo/tree/{version}"
    expected_license = f"https://github.com/MetaCubeX/mihomo/blob/{version}/LICENSE"
    if validate_https_url(seed["sourceURL"], "sourceURL") != expected_source:
        fail("sourceURL must point at the exact upstream tag")
    if validate_https_url(seed["licenseURL"], "licenseURL") != expected_license:
        fail("licenseURL must point at the exact upstream tag")
    return seed


def validate_compatibility(
    report: dict[str, Any],
    *,
    expected_core_id: str | None = None,
    production: bool = False,
    dedicated_host_evidence: Path | None = None,
    performance_review: Path | None = None,
) -> dict[str, Any]:
    # The executable Compatibility Lab owns the production evidence contract.
    # Import lazily so the standalone release scripts remain dependency-free
    # and the Pack's legacy parser fixture remains usable in non-production
    # policy tests.
    lab_directory = Path(__file__).resolve().parent / "CompatibilityLab"
    if str(lab_directory) not in sys.path:
        sys.path.insert(0, str(lab_directory))
    try:
        from compatibility_lab import CompatibilityError as LabCompatibilityError
        from compatibility_lab import validate_report as validate_lab_report
    except ImportError as error:
        fail(f"Compatibility Lab validator is unavailable: {error}")
    try:
        return validate_lab_report(
            report,
            production=production,
            expected_core_id=expected_core_id,
            dedicated_host_evidence_path=dedicated_host_evidence,
            performance_review_path=performance_review,
        )
    except LabCompatibilityError as error:
        fail(str(error))


def validate_file_index(
    files: Any,
    *,
    production: bool = False,
) -> list[dict[str, Any]]:
    if not isinstance(files, list) or not files or len(files) > MAX_FILES:
        fail("Core file index must be a non-empty bounded array")
    if len(files) != len(ROLE_PATHS):
        fail("Core file index must contain exactly the fixed release files")
    if [item.get("role") if isinstance(item, dict) else None for item in files] != list(ROLE_PATHS):
        fail("Core file index must use the fixed deterministic role order")
    roles: set[str] = set()
    paths: set[str] = set()
    for item in files:
        if not isinstance(item, dict) or set(item) != {"role", "relativePath", "url", "size", "sha256", "mode"}:
            fail("Core file index item fields differ from the fixed schema")
        role = item["role"]
        path = item["relativePath"]
        if role not in ROLE_PATHS or role in roles or path in paths:
            fail("Core file index contains an unknown or duplicate role/path")
        if path != ROLE_PATHS[role] or item["mode"] != ROLE_MODES[role]:
            fail(f"Core file mapping or mode is invalid for role {role}")
        if production:
            validate_production_https_url(item["url"], f"{role} URL")
        else:
            validate_https_url(item["url"], f"{role} URL")
        if not isinstance(item["size"], int) or item["size"] <= 0:
            fail(f"Core file size is invalid for role {role}")
        if SHA256_PATTERN.fullmatch(str(item["sha256"])) is None:
            fail(f"Core file SHA-256 is invalid for role {role}")
        roles.add(role)
        paths.add(path)
    if roles != set(ROLE_PATHS):
        fail("Core file roles do not match the fixed release contract")
    return files


def _validate_strings(value: Any, path: str = "catalog") -> None:
    if isinstance(value, str):
        if len(value) > MAX_STRING_LENGTH:
            fail(f"string exceeds limit at {path}")
    elif isinstance(value, list):
        for index, item in enumerate(value):
            _validate_strings(item, f"{path}[{index}]")
    elif isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str) or len(key) > 128:
                fail(f"invalid object key at {path}")
            _validate_strings(item, f"{path}.{key}")


def validate_catalog(
    raw: bytes,
    *,
    compatibility_report: Path | None = None,
    dedicated_host_evidence: Path | None = None,
    performance_review: Path | None = None,
    prior_raw: bytes | None = None,
    production: bool = False,
) -> dict[str, Any]:
    if len(raw) > MAX_CATALOG_BYTES:
        fail("Core Catalog exceeds 2 MiB")
    try:
        catalog = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"Core Catalog JSON is invalid: {error}")
    if not isinstance(catalog, dict) or raw != canonical_json_bytes(catalog):
        fail("Core Catalog must use deterministic sorted compact UTF-8 JSON with one final LF")
    if set(catalog) != {"schemaVersion", "sequence", "generatedAt", "expiresAt", "catalogKeySetVersion", "entries"}:
        fail("Core Catalog top-level fields differ from schema v1")
    if catalog["schemaVersion"] != 1:
        fail("unsupported Core Catalog schema")
    if not isinstance(catalog["sequence"], int) or isinstance(catalog["sequence"], bool) or catalog["sequence"] < 1:
        fail("Core Catalog sequence must be positive")
    if not isinstance(catalog["catalogKeySetVersion"], int) or catalog["catalogKeySetVersion"] < 1:
        fail("Core Catalog key set version must be positive")
    generated = parse_time(catalog["generatedAt"], "catalog generatedAt")
    expires = parse_time(catalog["expiresAt"], "catalog expiresAt")
    if expires <= generated:
        fail("Core Catalog expiry must follow generation")
    entries = catalog["entries"]
    if not isinstance(entries, list) or len(entries) > MAX_ENTRIES:
        fail("Core Catalog entries exceed policy")
    _validate_strings(catalog)
    seen: set[str] = set()
    recommended = 0
    compatibility = None
    compatibility_hash = None
    if compatibility_report is not None:
        compatibility_raw = read_regular_bytes(compatibility_report, maximum=1024 * 1024)
        compatibility = validate_compatibility(
            json.loads(compatibility_raw),
            production=production,
            dedicated_host_evidence=dedicated_host_evidence,
            performance_review=performance_review,
        )
        compatibility_hash = sha256_bytes(compatibility_raw)
    for entry in entries:
        if not isinstance(entry, dict):
            fail("Core Catalog entries must be objects")
        required = {"coreID", "upstreamVersion", "packageRevision", "status", "publishedAt", "releaseNotesURL", "upstream", "vela", "files"}
        allowed = required | {"blockReason"}
        if not required.issubset(entry) or not set(entry).issubset(allowed):
            fail(f"Core Catalog entry fields differ from schema: {entry.get('coreID', 'unknown')}")
        core_id = entry["coreID"]
        match = CORE_ID_PATTERN.fullmatch(str(core_id))
        if match is None or core_id in seen:
            fail("Core Catalog coreID is invalid or duplicated")
        seen.add(core_id)
        if entry["upstreamVersion"] != f"v{match.group(1)}" or entry["packageRevision"] != int(match.group(2)):
            fail(f"Core Catalog version/revision differs from coreID {core_id}")
        status = entry["status"]
        if status not in CATALOG_STATUSES:
            fail(f"Core Catalog status is invalid for {core_id}")
        if status == "recommended":
            recommended += 1
        if status in {"blocked", "withdrawn"}:
            reason = entry.get("blockReason")
            if (
                not isinstance(reason, str)
                or not reason.strip()
                or len(reason) > 1024
                or any(ord(character) < 0x20 and character not in "\t\n" for character in reason)
            ):
                fail(f"{status} Core {core_id} requires a bounded incident reason")
        elif "blockReason" in entry:
            fail(f"only blocked/withdrawn Core entries may have blockReason: {core_id}")
        parse_time(entry["publishedAt"], f"{core_id} publishedAt")
        if production:
            validate_production_https_url(
                entry["releaseNotesURL"],
                f"{core_id} releaseNotesURL",
            )
        else:
            validate_https_url(entry["releaseNotesURL"], f"{core_id} releaseNotesURL")
        validate_file_index(entry["files"], production=production)
        upstream = entry["upstream"]
        expected_upstream = {"tag", "commit", "assetName", "assetURL", "archiveSHA256", "archiveSizeBytes", "repositoryURL", "sourceURL", "license"}
        if not isinstance(upstream, dict) or set(upstream) != expected_upstream:
            fail(f"upstream metadata differs from schema for {core_id}")
        seed_view = {
            "schemaVersion": 1,
            "version": entry["upstreamVersion"],
            "tag": upstream["tag"],
            "commit": upstream["commit"],
            "assetName": upstream["assetName"],
            "assetURL": upstream["assetURL"],
            "archiveSHA256": upstream["archiveSHA256"],
            "archiveSizeBytes": upstream["archiveSizeBytes"],
            "sourceURL": upstream["sourceURL"],
            "licenseURL": f"https://github.com/MetaCubeX/mihomo/blob/{upstream['tag']}/LICENSE",
        }
        validate_seed(seed_view)
        if upstream["repositoryURL"] != "https://github.com/MetaCubeX/mihomo" or upstream["license"] not in {"GPL-3.0", "GPL-3.0-only"}:
            fail(f"upstream repository/license is invalid for {core_id}")
        vela = entry["vela"]
        vela_required = {
            "architectures", "bundleIdentifier", "compatibilityReportSHA256", "compatibilitySuiteVersion",
            "controllerAPIProfile", "dataSchemaMaximum", "dataSchemaMinimum", "helperProtocolMaximum",
            "helperProtocolMinimum", "maximumVelaBuild", "minimumMacOS", "minimumVelaBuild", "minimumVelaVersion",
        }
        if not isinstance(vela, dict) or set(vela) != vela_required:
            fail(f"Vela compatibility fields differ from schema for {core_id}")
        if vela["architectures"] != ["arm64"] or vela["minimumMacOS"] != "15.0":
            fail(f"Core {core_id} must be arm64-only and require macOS 15.0")
        if SHA256_PATTERN.fullmatch(str(vela["compatibilityReportSHA256"])) is None:
            fail(f"Core {core_id} has invalid compatibility report SHA-256")
        if not isinstance(vela["compatibilitySuiteVersion"], int) or vela["compatibilitySuiteVersion"] < 1:
            fail(f"Core {core_id} has invalid compatibility suite version")
        if status in {"recommended", "available"} and compatibility is not None:
            if compatibility["coreID"] != core_id or compatibility["result"] != "passed":
                fail(f"Core {core_id} cannot be published without a passed matching compatibility report")
            if vela["compatibilityReportSHA256"] != compatibility_hash or vela["compatibilitySuiteVersion"] != compatibility["suiteVersion"]:
                fail(f"Core {core_id} compatibility report hash/suite mismatch")
    if recommended > 1:
        fail("Core Catalog may contain at most one recommended entry")
    if prior_raw is not None:
        prior = validate_catalog(prior_raw)
        prior_sequence = prior["sequence"]
        if catalog["sequence"] < prior_sequence:
            fail("Core Catalog sequence replay rejected")
        if catalog["sequence"] == prior_sequence:
            if sha256_bytes(raw) != sha256_bytes(prior_raw):
                fail("same Core Catalog sequence with different raw bytes rejected")
            return catalog
        if catalog["sequence"] != prior_sequence + 1:
            fail("Core Catalog sequence must exactly follow the immutable prior sequence")
        prior_entries = {item["coreID"]: item for item in prior["entries"]}
        current_entries = {item["coreID"]: item for item in entries}
        missing = set(prior_entries) - set(current_entries)
        if missing:
            fail(
                "Core Catalog may not omit prior immutable entries/tombstones: "
                + ", ".join(sorted(missing))
            )
        for core_id, prior_entry in prior_entries.items():
            entry = current_entries[core_id]
            prior_immutable = {
                key: value
                for key, value in prior_entry.items()
                if key not in {"status", "blockReason"}
            }
            current_immutable = {
                key: value
                for key, value in entry.items()
                if key not in {"status", "blockReason"}
            }
            if current_immutable != prior_immutable:
                fail(f"prior Core metadata/files are immutable across Catalog sequences: {core_id}")
            previous_status = prior_entry["status"]
            current_status = entry["status"]
            allowed = {
                "recommended": {"recommended", "available", "blocked", "withdrawn"},
                "available": {"recommended", "available", "blocked", "withdrawn"},
                "blocked": {"blocked", "withdrawn"},
                "withdrawn": {"withdrawn"},
            }
            if current_status not in allowed[previous_status]:
                fail(
                    f"forbidden Core status transition {core_id}: "
                    f"{previous_status} -> {current_status}"
                )
    return catalog


def validate_signature_envelope(raw: bytes, catalog_raw: bytes, *, production: bool) -> dict[str, Any]:
    if len(raw) > MAX_SIGNATURE_BYTES:
        fail("Core Catalog signature envelope exceeds 64 KiB")
    try:
        envelope = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"Core Catalog signature envelope is invalid: {error}")
    if not isinstance(envelope, dict) or set(envelope) != {"schemaVersion", "catalogSHA256", "signatures"}:
        fail("Core Catalog signature envelope fields differ from schema v1")
    if envelope["schemaVersion"] != 1 or envelope["catalogSHA256"] != sha256_bytes(catalog_raw):
        fail("Core Catalog signature envelope digest/schema mismatch")
    signatures = envelope["signatures"]
    if not isinstance(signatures, list) or not 1 <= len(signatures) <= 8:
        fail("Core Catalog signature count is invalid")
    seen: set[str] = set()
    for item in signatures:
        if not isinstance(item, dict) or set(item) != {"keyID", "algorithm", "signature"}:
            fail("Core Catalog signature item fields differ from schema")
        key_id = item["keyID"]
        if not isinstance(key_id, str) or not key_id or len(key_id) > 128 or key_id in seen:
            fail("Core Catalog key IDs must be unique bounded strings")
        if production and "TEST" in key_id.upper():
            fail("test Core Catalog key is forbidden in production")
        if item["algorithm"] != "ed25519":
            fail("Core Catalog signatures must use Ed25519")
        try:
            import base64
            decoded = base64.b64decode(item["signature"], validate=True)
        except Exception:
            fail(f"Core Catalog signature is not valid Base64: {key_id}")
        if len(decoded) != 64:
            fail(f"Core Catalog Ed25519 signature must be 64 bytes: {key_id}")
        seen.add(key_id)
    return envelope
