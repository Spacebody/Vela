#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from core_release_lib import (
    CATALOG_STATUSES,
    CORE_ID_PATTERN,
    CoreReleaseError,
    atomic_write,
    canonical_json_bytes,
    load_json,
    parse_time,
    read_regular_bytes,
    sha256_bytes,
    validate_catalog,
    validate_compatibility,
    validate_file_index,
    validate_https_url,
    validate_seed,
)


TERMINAL_STATUSES = {"blocked", "withdrawn"}
ALLOWED_TRANSITIONS = {
    "recommended": {"recommended", "available", "blocked", "withdrawn"},
    "available": {"recommended", "available", "blocked", "withdrawn"},
    "blocked": {"blocked", "withdrawn"},
    "withdrawn": {"withdrawn"},
}


def validate_incident_reason(reason: Any, status: str) -> str | None:
    if status in TERMINAL_STATUSES:
        if (
            not isinstance(reason, str)
            or not reason.strip()
            or len(reason) > 1024
            or any(
                ord(character) < 0x20 and character not in "\t\n"
                for character in reason
            )
        ):
            raise CoreReleaseError(
                f"{status} status requires a bounded incident reason"
            )
        return reason
    if reason is not None:
        raise CoreReleaseError(
            f"{status} status must not carry a terminal incident reason"
        )
    return None


def apply_status_transition(
    entry: dict[str, Any],
    status: str,
    reason: Any,
) -> None:
    previous = entry["status"]
    if status not in ALLOWED_TRANSITIONS[previous]:
        raise CoreReleaseError(
            f"forbidden Core status transition {entry['coreID']}: {previous} -> {status}"
        )
    reason = validate_incident_reason(reason, status)
    entry["status"] = status
    entry.pop("blockReason", None)
    if reason is not None:
        entry["blockReason"] = reason


def load_status_transitions(path: Path | None) -> list[dict[str, Any]]:
    if path is None:
        return []
    try:
        value = json.loads(read_regular_bytes(path, maximum=128 * 1024))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CoreReleaseError(f"status transitions JSON is invalid: {error}") from error
    if not isinstance(value, list) or len(value) > 100:
        raise CoreReleaseError("status transitions must be a bounded JSON array")
    seen: set[str] = set()
    for item in value:
        if not isinstance(item, dict) or set(item) != {
            "coreID", "status", "blockReason",
        }:
            raise CoreReleaseError("status transition fields are invalid")
        core_id = item["coreID"]
        if (
            not isinstance(core_id, str)
            or CORE_ID_PATTERN.fullmatch(core_id) is None
            or core_id in seen
        ):
            raise CoreReleaseError("status transition Core IDs must be unique and valid")
        if item["status"] not in CATALOG_STATUSES:
            raise CoreReleaseError("status transition status is invalid")
        validate_incident_reason(item["blockReason"], item["status"])
        seen.add(core_id)
    return value


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate deterministic raw Core Catalog bytes")
    parser.add_argument("--seed", required=True)
    parser.add_argument("--compatibility-report", required=True)
    parser.add_argument("--dedicated-host-evidence")
    parser.add_argument("--performance-review")
    parser.add_argument("--file-index", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--sequence", type=int, required=True)
    parser.add_argument("--generated-at", required=True)
    parser.add_argument("--expires-at", required=True)
    parser.add_argument("--published-at", required=True)
    parser.add_argument("--key-set-version", type=int, default=1)
    parser.add_argument("--status", choices=sorted(CATALOG_STATUSES), required=True)
    parser.add_argument("--block-reason")
    parser.add_argument("--release-notes-url", required=True)
    parser.add_argument("--bundle-identifier", required=True)
    parser.add_argument("--minimum-vela-version", default="0.6.0")
    parser.add_argument("--minimum-vela-build", type=int, default=2026071302)
    parser.add_argument("--maximum-vela-build", type=int)
    parser.add_argument("--helper-protocol-minimum", type=int, default=2)
    parser.add_argument("--helper-protocol-maximum", type=int, default=2)
    parser.add_argument("--data-schema-minimum", type=int, default=6)
    parser.add_argument("--data-schema-maximum", type=int, default=6)
    parser.add_argument("--prior-catalog")
    parser.add_argument("--status-transitions")
    parser.add_argument("--production", action="store_true")
    args = parser.parse_args()
    try:
        if args.sequence < 1 or args.key_set_version < 1:
            raise CoreReleaseError("sequence and key-set-version must be positive")
        validate_incident_reason(args.block_reason, args.status)
        seed = validate_seed(load_json(Path(args.seed), maximum=64 * 1024))
        report_path = Path(args.compatibility_report)
        report_raw = read_regular_bytes(report_path, maximum=1024 * 1024)
        report = validate_compatibility(
            json.loads(report_raw),
            production=args.production,
            dedicated_host_evidence=(
                Path(args.dedicated_host_evidence)
                if args.dedicated_host_evidence
                else None
            ),
            performance_review=(
                Path(args.performance_review) if args.performance_review else None
            ),
        )
        if args.status in {"available", "recommended"} and report["result"] != "passed":
            raise CoreReleaseError("available/recommended Core requires a passed compatibility report")
        files = validate_file_index(json.loads(read_regular_bytes(Path(args.file_index), maximum=1024 * 1024)))
        version = seed["version"]
        revision_text = report["coreID"].removeprefix(version + "-r")
        if not revision_text.isdigit() or report["coreID"] != f"{version}-r{int(revision_text)}":
            raise CoreReleaseError("compatibility report coreID does not match upstream version/revision")
        for label, value in [("generatedAt", args.generated_at), ("expiresAt", args.expires_at), ("publishedAt", args.published_at)]:
            parse_time(value, label)
        validate_https_url(args.release_notes_url, "release notes URL")
        entry = {
            "coreID": report["coreID"],
            "upstreamVersion": version,
            "packageRevision": int(revision_text),
            "status": args.status,
            "publishedAt": args.published_at,
            "releaseNotesURL": args.release_notes_url,
            "upstream": {
                "tag": seed["tag"],
                "commit": seed["commit"],
                "assetName": seed["assetName"],
                "assetURL": seed["assetURL"],
                "archiveSHA256": seed["archiveSHA256"],
                "archiveSizeBytes": seed["archiveSizeBytes"],
                "repositoryURL": "https://github.com/MetaCubeX/mihomo",
                "sourceURL": seed["sourceURL"],
                "license": "GPL-3.0-only",
            },
            "vela": {
                "architectures": ["arm64"],
                "bundleIdentifier": args.bundle_identifier,
                "compatibilityReportSHA256": sha256_bytes(report_raw),
                "compatibilitySuiteVersion": report["suiteVersion"],
                "controllerAPIProfile": "mihomo-v1.19.28",
                "dataSchemaMaximum": args.data_schema_maximum,
                "dataSchemaMinimum": args.data_schema_minimum,
                "helperProtocolMaximum": args.helper_protocol_maximum,
                "helperProtocolMinimum": args.helper_protocol_minimum,
                "maximumVelaBuild": args.maximum_vela_build,
                "minimumMacOS": "15.0",
                "minimumVelaBuild": args.minimum_vela_build,
                "minimumVelaVersion": args.minimum_vela_version,
            },
            "files": files,
        }
        if args.block_reason:
            entry["blockReason"] = args.block_reason
        prior_raw = read_regular_bytes(Path(args.prior_catalog), maximum=2 * 1024 * 1024) if args.prior_catalog else None
        transitions = load_status_transitions(
            Path(args.status_transitions) if args.status_transitions else None
        )
        entries: list[dict[str, Any]] = []
        if prior_raw is not None:
            prior_catalog = validate_catalog(prior_raw)
            entries = list(prior_catalog["entries"])
        elif transitions:
            raise CoreReleaseError("status transitions require a verified prior Catalog")

        current_index = next(
            (index for index, item in enumerate(entries) if item["coreID"] == entry["coreID"]),
            None,
        )
        transition_ids = {item["coreID"] for item in transitions}
        if entry["coreID"] in transition_ids:
            raise CoreReleaseError(
                "the current Core status is controlled by --status/--block-reason, not status transitions"
            )
        by_id = {item["coreID"]: item for item in entries}
        for transition in transitions:
            existing = by_id.get(transition["coreID"])
            if existing is None:
                raise CoreReleaseError(
                    f"status transition targets an unknown prior Core: {transition['coreID']}"
                )
            apply_status_transition(
                existing,
                transition["status"],
                transition["blockReason"],
            )

        if current_index is None:
            entries.append(entry)
        else:
            existing = entries[current_index]
            for field in (
                "coreID", "upstreamVersion", "packageRevision", "upstream", "vela", "files",
            ):
                if existing[field] != entry[field]:
                    raise CoreReleaseError(
                        f"existing Core ID metadata/files are immutable: {entry['coreID']}"
                    )
            apply_status_transition(existing, args.status, args.block_reason)

        catalog = {
            "schemaVersion": 1,
            "sequence": args.sequence,
            "generatedAt": args.generated_at,
            "expiresAt": args.expires_at,
            "catalogKeySetVersion": args.key_set_version,
            "entries": entries,
        }
        raw = canonical_json_bytes(catalog)
        validate_catalog(
            raw,
            compatibility_report=report_path,
            dedicated_host_evidence=(
                Path(args.dedicated_host_evidence)
                if args.dedicated_host_evidence
                else None
            ),
            performance_review=(
                Path(args.performance_review) if args.performance_review else None
            ),
            prior_raw=prior_raw,
            production=args.production,
        )
        atomic_write(Path(args.output), raw)
        print(f"Generated deterministic Core Catalog: sequence={args.sequence} status={args.status} sha256={sha256_bytes(raw)}")
        return 0
    except (OSError, UnicodeError, json.JSONDecodeError, CoreReleaseError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
