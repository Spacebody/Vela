#!/usr/bin/env python3
"""Validate the V1 Release Candidate feature-freeze policy."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


TOP_LEVEL = {
    "schemaVersion",
    "active",
    "targetRelease",
    "defaultDecision",
    "normalMergeContractImpact",
    "allowedChangeClasses",
    "forbiddenAdditions",
    "requiredChangeMetadata",
    "contractChangeApproval",
}
ALLOWED_CHANGE_CLASSES = {
    "securityFix",
    "dataIntegrityFix",
    "crashFix",
    "reliabilityFix",
    "performanceFix",
    "accessibilityFix",
    "localizationOrDocumentation",
    "releaseEngineering",
}
FORBIDDEN_ADDITIONS = {
    "featureFlag",
    "appDestination",
    "appIntentIdentifier",
    "cliCommand",
    "automationCommand",
    "helperRPC",
    "networkEndpointCategory",
    "permission",
    "keychainSecretType",
    "persistentSchema",
    "trustRoot",
    "bundledExecutableOrFramework",
    "updateChannel",
    "coreChannel",
}
REQUIRED_METADATA = {
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
}
APPROVAL_KEYS = {
    "adrRequired",
    "newReleaseCandidateRequired",
    "fullMigrationAndUpdateMatrixRequired",
    "requiredApprovals",
}
APPROVAL_ROLES = ["releaseOwner", "securityOwner", "productOwner"]


class FreezeError(ValueError):
    pass


def exact_set(value: object, expected: set[str], label: str) -> None:
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        raise FreezeError(f"{label} must be an array of strings")
    if len(value) != len(set(value)):
        raise FreezeError(f"{label} contains duplicates")
    actual = set(value)
    if actual != expected:
        raise FreezeError(
            f"{label} differs; missing={sorted(expected - actual)}, "
            f"extra={sorted(actual - expected)}"
        )


def validate(value: dict) -> None:
    if set(value) != TOP_LEVEL:
        raise FreezeError(
            f"feature-freeze keys differ; missing={sorted(TOP_LEVEL - set(value))}, "
            f"extra={sorted(set(value) - TOP_LEVEL)}"
        )
    if value.get("schemaVersion") != 1:
        raise FreezeError("feature-freeze schemaVersion must be 1")
    if value.get("active") is not True or value.get("defaultDecision") != "deny":
        raise FreezeError("feature freeze must be active and default-deny")
    if value.get("normalMergeContractImpact") != "none":
        raise FreezeError("normal RC merge contract impact must be none")
    if re.fullmatch(r"\d+\.\d+\.\d+", str(value.get("targetRelease"))) is None:
        raise FreezeError("targetRelease must be a stable SemVer")
    exact_set(
        value.get("allowedChangeClasses"),
        ALLOWED_CHANGE_CLASSES,
        "allowedChangeClasses",
    )
    exact_set(
        value.get("forbiddenAdditions"),
        FORBIDDEN_ADDITIONS,
        "forbiddenAdditions",
    )
    exact_set(
        value.get("requiredChangeMetadata"),
        REQUIRED_METADATA,
        "requiredChangeMetadata",
    )
    approval = value.get("contractChangeApproval")
    if not isinstance(approval, dict) or set(approval) != APPROVAL_KEYS:
        raise FreezeError("contractChangeApproval shape changed")
    for key in (
        "adrRequired",
        "newReleaseCandidateRequired",
        "fullMigrationAndUpdateMatrixRequired",
    ):
        if approval.get(key) is not True:
            raise FreezeError(f"contractChangeApproval.{key} must be true")
    if approval.get("requiredApprovals") != APPROVAL_ROLES:
        raise FreezeError(
            "contract changes require releaseOwner, securityOwner, and productOwner"
        )
    serialized = json.dumps(value)
    if any(token in serialized for token in ("REPLACE_WITH", "__", "TODO", "TBD")):
        raise FreezeError("feature-freeze policy contains a placeholder")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("config")
    args = parser.parse_args()
    path = Path(args.config)
    try:
        if not path.is_file() or path.is_symlink():
            raise FreezeError(f"expected a regular feature-freeze file: {path}")
        value = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(value, dict):
            raise FreezeError("feature-freeze policy must be a JSON object")
        validate(value)
    except (FreezeError, OSError, UnicodeError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print("Feature Freeze validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
