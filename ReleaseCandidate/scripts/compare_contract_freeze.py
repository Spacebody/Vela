#!/usr/bin/env python3
"""Compare public contracts with default-deny, validated ADR exceptions."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


ADR_KEYS = {
    "schemaVersion",
    "adrID",
    "status",
    "issueID",
    "changeClass",
    "firstAffectedVersion",
    "summary",
    "changes",
    "compatibility",
    "migrationAndRollback",
    "securityAndPrivacy",
    "tests",
    "approvals",
    "contractBinding",
}
CONTRACT_BINDING_KEYS = {
    "baselineCanonicalSHA256",
    "currentCanonicalSHA256",
}
CHANGE_KEYS = {
    "path",
    "classification",
    "breaking",
    "rationale",
    "before",
    "after",
}
CLASSIFICATIONS = {
    "compatibleAddition",
    "semanticCorrection",
    "securityProvisioning",
    "bugFix",
    "schemaVersionedChange",
}
COMPATIBILITY_KEYS = {
    "cli",
    "appIntents",
    "helper",
    "automation",
    "dataMigration",
    "appUpdate",
    "coreUpdate",
    "documentation",
}
APPROVAL_ROLES = {"releaseOwner", "securityOwner", "productOwner"}
APPROVAL_KEYS = {"approvedBy", "approvedAt"}
PLACEHOLDERS = ("REPLACE_WITH", "__", "TODO", "TBD", "example.com")
SEMVER = re.compile(
    r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
)


class CompareError(ValueError):
    pass


@dataclass(frozen=True)
class Change:
    path: str
    golden: Any
    current: Any


def load_object(path: Path, label: str) -> dict:
    if not path.is_file() or path.is_symlink():
        raise CompareError(f"expected a regular {label} file: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise CompareError(f"cannot read {label} {path}: {error}") from error
    if not isinstance(value, dict):
        raise CompareError(f"{label} must be a JSON object")
    return value


def pointer_component(value: str) -> str:
    return value.replace("~", "~0").replace("/", "~1")


def child_path(path: str, component: str) -> str:
    encoded = pointer_component(component)
    return f"{path}/{encoded}" if path else f"/{encoded}"


def trust_root_records(value: object) -> dict[str, dict] | None:
    if not isinstance(value, list):
        return None
    records: dict[str, dict] = {}
    for item in value:
        if not isinstance(item, dict):
            return None
        kind = item.get("kind")
        if not isinstance(kind, str) or not kind or kind in records:
            return None
        records[kind] = item
    return records


def diff(golden: Any, current: Any, path: str = "") -> list[Change]:
    if isinstance(golden, dict) and isinstance(current, dict):
        changes: list[Change] = []
        for key in sorted(set(golden) | set(current)):
            nested = child_path(path, key)
            if key not in golden:
                changes.append(Change(nested, None, current[key]))
            elif key not in current:
                changes.append(Change(nested, golden[key], None))
            else:
                changes.extend(diff(golden[key], current[key], nested))
        return changes
    # Trust roots are identified by their frozen kind, not by array position.
    # Report each changed record as one semantic path so an ADR must bind the
    # complete before/after record and cannot approve a misleading index shift.
    if isinstance(golden, list) and isinstance(current, list):
        if path == "/trustRoots":
            old_roots = trust_root_records(golden)
            new_roots = trust_root_records(current)
            if old_roots is not None and new_roots is not None:
                changes: list[Change] = []
                for kind in sorted(set(old_roots) | set(new_roots)):
                    before = old_roots.get(kind)
                    after = new_roots.get(kind)
                    if before != after:
                        changes.append(
                            Change(child_path(path, kind), before, after)
                        )
                return changes
        # Other arrays are ordered registries. Report the registry as one
        # semantic path so an ADR cannot approve only a misleading index shift.
        return [] if golden == current else [Change(path or "/", golden, current)]
    return [] if golden == current else [Change(path or "/", golden, current)]


def canonical_digest(value: object) -> str:
    canonical = json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def added_values(before: object, after: object) -> set[object]:
    if not isinstance(before, list) or not isinstance(after, list):
        return set()
    hashable_before = {json.dumps(item, sort_keys=True) for item in before}
    return {
        item
        for item in (json.dumps(value, sort_keys=True) for value in after)
        if item not in hashable_before
    }


def empty_trust_identifier(value: object) -> bool:
    return value is None or value == "" or value == []


def configured_trust_identifier(value: object, empty_value: object) -> bool:
    if isinstance(empty_value, list):
        return (
            isinstance(value, list)
            and bool(value)
            and all(isinstance(item, str) and bool(item) for item in value)
            and len(value) == len(set(value))
        )
    return isinstance(value, str) and bool(value)


def exact_trust_provisioning(before: dict, after: dict) -> bool:
    if set(before) != set(after) or before.get("kind") != after.get("kind"):
        return False
    if before.get("status") != "unprovisioned" or after.get("status") != "configured":
        return False
    before_identifier = before.get("identifier")
    if not empty_trust_identifier(before_identifier):
        return False
    if not configured_trust_identifier(after.get("identifier"), before_identifier):
        return False
    return all(
        before.get(key) == after.get(key)
        for key in before
        if key not in {"identifier", "status"}
    )


def trust_root_change_reasons(golden: dict, current: dict) -> list[str]:
    before = trust_root_records(golden.get("trustRoots"))
    after = trust_root_records(current.get("trustRoots"))
    if before is None or after is None:
        return ["malformed or duplicate trust-root record"]

    reasons: list[str] = []
    for kind in sorted(set(after) - set(before)):
        reasons.append(f"new trust-root record/category: {kind}")
    for kind in sorted(set(before) - set(after)):
        reasons.append(f"trust-root record removed outside exact provisioning: {kind}")
    for kind in sorted(set(before) & set(after)):
        old_record = before[kind]
        new_record = after[kind]
        if old_record == new_record or exact_trust_provisioning(old_record, new_record):
            continue
        old_identifier = old_record.get("identifier")
        new_identifier = new_record.get("identifier")
        if old_identifier != new_identifier:
            reasons.append(
                f"new or changed trust-root identifier/key ID outside exact provisioning: {kind}"
            )
        else:
            reasons.append(
                f"trust-root record changed outside exact provisioning: {kind}"
            )
    return reasons


def forbidden_addition_reasons(golden: dict, current: dict) -> list[str]:
    reasons: list[str] = []
    if golden.get("protocols", {}).get("automation") is None and current.get(
        "protocols", {}
    ).get("automation") is not None:
        reasons.append("new Automation protocol")
    if golden.get("cli", {}).get("availability") == "absent" and current.get(
        "cli", {}
    ).get("availability") != "absent":
        reasons.append("new CLI surface")
    if golden.get("appIntents", {}).get("availability") == "absent" and current.get(
        "appIntents", {}
    ).get("availability") != "absent":
        reasons.append("new App Intent surface")
    if golden.get("identifiers", {}).get("cli") is None and current.get(
        "identifiers", {}
    ).get("cli") is not None:
        reasons.append("new CLI identifier")

    old_methods = golden.get("protocols", {}).get("helper", {}).get("methods", [])
    new_methods = current.get("protocols", {}).get("helper", {}).get("methods", [])
    if added_values(old_methods, new_methods):
        reasons.append("new Helper RPC")
    old_operations = golden.get("configuration", {}).get("operationKinds", [])
    new_operations = current.get("configuration", {}).get("operationKinds", [])
    if added_values(old_operations, new_operations):
        reasons.append("new configuration operation kind")
    if added_values(golden.get("helpTopics", []), current.get("helpTopics", [])):
        reasons.append("new Help Topic identifier")
    if added_values(golden.get("urlSchemes", []), current.get("urlSchemes", [])):
        reasons.append("new URL scheme")
    if added_values(golden.get("keychain", []), current.get("keychain", [])):
        reasons.append("new Keychain secret category")
    if added_values(golden.get("userDefaults", []), current.get("userDefaults", [])):
        reasons.append("new migration-relevant UserDefaults key")

    old_schema_keys = set(golden.get("schemas", {}))
    new_schema_keys = set(current.get("schemas", {}))
    if new_schema_keys - old_schema_keys:
        reasons.append("new persistent/public schema category")
    reasons.extend(trust_root_change_reasons(golden, current))

    removed_absence = set(golden.get("absentSurfaces", [])) - set(
        current.get("absentSurfaces", [])
    )
    if removed_absence:
        reasons.append(
            "newly implemented frozen-absent surface: " + ", ".join(sorted(removed_absence))
        )
    return reasons


def nonempty_text(value: object, label: str, minimum: int = 3) -> str:
    if not isinstance(value, str) or len(value.strip()) < minimum:
        raise CompareError(f"ADR {label} must be meaningful text")
    if any(token.lower() in value.lower() for token in PLACEHOLDERS):
        raise CompareError(f"ADR {label} contains a placeholder")
    return value.strip()


def validate_timestamp(value: object, label: str) -> None:
    text = nonempty_text(value, label)
    normalized = text[:-1] + "+00:00" if text.endswith("Z") else text
    try:
        parsed = dt.datetime.fromisoformat(normalized)
    except ValueError as error:
        raise CompareError(f"ADR {label} must be RFC 3339") from error
    if parsed.tzinfo is None:
        raise CompareError(f"ADR {label} must include a timezone")


def validate_adr(
    value: dict,
    allowed_change_classes: set[str],
    required_roles: set[str],
    golden: dict,
    current: dict,
    actual_changes: dict[str, Change],
) -> set[str]:
    if set(value) != ADR_KEYS:
        raise CompareError(
            f"ADR keys differ; missing={sorted(ADR_KEYS - set(value))}, "
            f"extra={sorted(set(value) - ADR_KEYS)}"
        )
    if value.get("schemaVersion") != 2 or value.get("status") != "accepted":
        raise CompareError("ADR must be schemaVersion 2 and accepted")
    nonempty_text(value.get("adrID"), "adrID")
    nonempty_text(value.get("issueID"), "issueID")
    nonempty_text(value.get("summary"), "summary", minimum=12)
    change_class = value.get("changeClass")
    if change_class not in allowed_change_classes:
        raise CompareError(f"ADR changeClass is not allowed during freeze: {change_class}")
    version = value.get("firstAffectedVersion")
    if not isinstance(version, str) or SEMVER.fullmatch(version) is None:
        raise CompareError("ADR firstAffectedVersion must be SemVer")

    binding = value.get("contractBinding")
    if not isinstance(binding, dict) or set(binding) != CONTRACT_BINDING_KEYS:
        raise CompareError("ADR contractBinding has an invalid shape")
    expected_baseline = canonical_digest(golden)
    expected_current = canonical_digest(current)
    if binding.get("baselineCanonicalSHA256") != expected_baseline:
        raise CompareError("ADR baseline canonical SHA-256 does not bind this contract")
    if binding.get("currentCanonicalSHA256") != expected_current:
        raise CompareError("ADR current canonical SHA-256 does not bind this contract")

    compatibility = value.get("compatibility")
    if not isinstance(compatibility, dict) or set(compatibility) != COMPATIBILITY_KEYS:
        raise CompareError("ADR compatibility assessment is incomplete")
    for key, text in compatibility.items():
        nonempty_text(text, f"compatibility.{key}")
    nonempty_text(
        value.get("migrationAndRollback"),
        "migrationAndRollback",
        minimum=12,
    )
    nonempty_text(
        value.get("securityAndPrivacy"),
        "securityAndPrivacy",
        minimum=12,
    )

    tests = value.get("tests")
    if not isinstance(tests, list) or not tests:
        raise CompareError("ADR tests must be a non-empty array")
    for index, test in enumerate(tests):
        nonempty_text(test, f"tests[{index}]", minimum=8)

    approvals = value.get("approvals")
    if not isinstance(approvals, dict) or set(approvals) != required_roles:
        raise CompareError("ADR must contain all required approval roles")
    approvers: list[str] = []
    for role in sorted(required_roles):
        approval = approvals.get(role)
        if not isinstance(approval, dict) or set(approval) != APPROVAL_KEYS:
            raise CompareError(f"ADR approval {role} has an invalid shape")
        approver = nonempty_text(approval.get("approvedBy"), f"{role}.approvedBy")
        validate_timestamp(approval.get("approvedAt"), f"{role}.approvedAt")
        approvers.append(approver)
    if len(set(approvers)) != len(approvers):
        raise CompareError("ADR approval roles must be held by distinct reviewers")

    changes = value.get("changes")
    if not isinstance(changes, list) or not changes:
        raise CompareError("ADR changes must be a non-empty array")
    paths: set[str] = set()
    for index, raw in enumerate(changes):
        if not isinstance(raw, dict) or set(raw) != CHANGE_KEYS:
            raise CompareError(f"ADR change {index} has an invalid shape")
        path = raw.get("path")
        if (
            not isinstance(path, str)
            or not path.startswith("/")
            or path == "/"
            or "//" in path
        ):
            raise CompareError(f"ADR change {index} has an invalid JSON Pointer")
        if path in paths:
            raise CompareError(f"ADR contains duplicate path approval: {path}")
        paths.add(path)
        if raw.get("classification") not in CLASSIFICATIONS:
            raise CompareError(f"ADR change {path} has an invalid classification")
        if not isinstance(raw.get("breaking"), bool):
            raise CompareError(f"ADR change {path} breaking must be boolean")
        if path.startswith("/trustRoots/") and (
            raw.get("classification") != "securityProvisioning"
            or raw.get("breaking") is not False
        ):
            raise CompareError(
                f"ADR trust-root change {path} must be non-breaking securityProvisioning"
            )
        nonempty_text(raw.get("rationale"), f"change {path} rationale", minimum=12)
        actual = actual_changes.get(path)
        if actual is None:
            raise CompareError(f"ADR change {path} does not bind an actual contract change")
        if raw.get("before") != actual.golden or raw.get("after") != actual.current:
            raise CompareError(f"ADR change {path} before/after binding is not exact")
    return paths


def load_freeze(path: Path) -> tuple[set[str], set[str]]:
    value = load_object(path, "feature-freeze")
    allowed = value.get("allowedChangeClasses")
    approval = value.get("contractChangeApproval")
    if not isinstance(allowed, list) or not isinstance(approval, dict):
        raise CompareError("feature-freeze policy is incomplete")
    roles = approval.get("requiredApprovals")
    if not isinstance(roles, list):
        raise CompareError("feature-freeze required approvals are incomplete")
    if set(roles) != APPROVAL_ROLES:
        raise CompareError("feature-freeze approval roles changed unexpectedly")
    return set(allowed), set(roles)


def report_value(changes: list[Change], approved: set[str]) -> dict:
    return {
        "schemaVersion": 1,
        "changes": [
            {
                "path": item.path,
                "approved": item.path in approved,
                "golden": item.golden,
                "current": item.current,
            }
            for item in changes
        ],
    }


def main() -> int:
    default_repo = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser()
    parser.add_argument("golden")
    parser.add_argument("current")
    parser.add_argument("--adr", action="append", default=[])
    parser.add_argument(
        "--feature-freeze",
        default=str(default_repo / "ReleaseCandidate/config/feature-freeze.json"),
    )
    parser.add_argument("--report")
    args = parser.parse_args()
    try:
        golden = load_object(Path(args.golden), "golden contract")
        current = load_object(Path(args.current), "current contract")
        changes = diff(golden, current)
        if not changes:
            if args.adr:
                raise CompareError("ADR supplied but the public contract did not change")
            if args.report:
                Path(args.report).write_text(
                    json.dumps(report_value([], set()), indent=2) + "\n",
                    encoding="utf-8",
                )
            print("Public Contract Freeze diff passed (no changes).")
            return 0

        forbidden = forbidden_addition_reasons(golden, current)
        if forbidden:
            raise CompareError(
                "feature freeze forbids this contract expansion even with an ADR:\n- "
                + "\n- ".join(forbidden)
            )
        allowed_classes, roles = load_freeze(Path(args.feature_freeze))
        approved: set[str] = set()
        actual_changes = {item.path: item for item in changes}
        for raw_path in args.adr:
            adr = load_object(Path(raw_path), "contract-change ADR")
            paths = validate_adr(
                adr,
                allowed_classes,
                roles,
                golden,
                current,
                actual_changes,
            )
            overlap = approved & paths
            if overlap:
                raise CompareError(
                    "multiple ADRs approve the same contract path: "
                    + ", ".join(sorted(overlap))
                )
            approved.update(paths)

        changed_paths = {item.path for item in changes}
        stale_approvals = approved - changed_paths
        if stale_approvals:
            raise CompareError(
                "ADR approves paths that did not change: "
                + ", ".join(sorted(stale_approvals))
            )
        unapproved = changed_paths - approved
        if args.report:
            Path(args.report).write_text(
                json.dumps(report_value(changes, approved), indent=2) + "\n",
                encoding="utf-8",
            )
        for change in changes:
            state = "APPROVED" if change.path in approved else "UNAPPROVED"
            print(f"{change.path}: {state}")
        if unapproved:
            raise CompareError(
                "Public Contract Freeze changed without an accepted, exact-path ADR:\n- "
                + "\n- ".join(sorted(unapproved))
            )
    except (CompareError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print("Public Contract Freeze diff passed with validated ADR approval.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
