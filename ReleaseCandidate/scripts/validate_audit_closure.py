#!/usr/bin/env python3
from __future__ import annotations

import argparse
from datetime import date
from pathlib import Path

from _common import (
    GateError,
    checked_evidence,
    git_output,
    load_json,
    main_error,
    reject_forbidden_text,
    valid_commit,
    valid_sha256,
    validate_schema,
)


CLOSED = {"verified", "outOfScope"}
MEDIUM_ACCEPTABLE = CLOSED | {"riskAccepted"}
RISK_KEYS = {
    "owner",
    "reason",
    "exposure",
    "mitigation",
    "expiresAt",
    "affectedVersion",
}


def verify_reference(reference: dict, root: Path, verify_files: bool) -> None:
    if not valid_sha256(reference.get("sha256")):
        raise GateError(f"invalid evidence SHA-256: {reference.get('path')}")
    if verify_files:
        checked_evidence(root, reference["path"], reference["sha256"])


def require_commit(root: Path, commit: str, label: str) -> None:
    try:
        git_output(root, "cat-file", "-e", f"{commit}^{{commit}}")
    except GateError as error:
        raise GateError(f"{label} does not exist in the repository: {error}") from error


def require_ancestor(root: Path, ancestor: str, descendant: str, label: str) -> None:
    try:
        git_output(root, "merge-base", "--is-ancestor", ancestor, descendant)
    except GateError as error:
        raise GateError(f"{label} is not an ancestor of the audited RC commit") from error


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate Vela external security-audit closure")
    parser.add_argument("manifest")
    parser.add_argument("--allow-pending", action="store_true")
    parser.add_argument("--as-of", default=date.today().isoformat())
    parser.add_argument("--repository-root", default=".")
    parser.add_argument("--evidence-root")
    parser.add_argument("--verify-files", action="store_true")
    parser.add_argument("--expected-commit")
    args = parser.parse_args()
    try:
        as_of = date.fromisoformat(args.as_of)
        value = load_json(Path(args.manifest), label="audit closure")
        validate_schema(value, "audit-closure.schema.json")
        reject_forbidden_text(value, label="audit closure")
        root = Path(args.repository_root)
        evidence_root = Path(args.evidence_root) if args.evidence_root else root
        errors: list[str] = []
        incomplete: list[str] = []

        baseline = value["scope"]["baselineCommit"]
        rc_commit = value["scope"]["rcCommit"]
        if not valid_commit(baseline):
            incomplete.append("audit baseline commit is missing or invalid")
        if not valid_commit(rc_commit):
            incomplete.append("audit RC commit is missing or invalid")
        if args.expected_commit and rc_commit != args.expected_commit:
            errors.append("audit RC commit differs from the candidate commit")
        if args.verify_files and valid_commit(baseline) and valid_commit(rc_commit):
            try:
                require_commit(root, baseline, "audit baseline commit")
                require_commit(root, rc_commit, "audit RC commit")
                require_ancestor(root, baseline, rc_commit, "audit baseline commit")
            except GateError as error:
                errors.append(str(error))

        for label, evidence in (
            ("delta review", value["scope"]["deltaReview"]),
            ("public summary", value["publicSummary"]),
        ):
            if evidence["status"] == "verified":
                if not isinstance(evidence["path"], str) or not valid_sha256(evidence["sha256"]):
                    errors.append(f"{label} lacks path/SHA-256")
                elif args.verify_files:
                    try:
                        checked_evidence(evidence_root, evidence["path"], evidence["sha256"])
                    except GateError as error:
                        errors.append(f"{label}: {error}")
            else:
                if evidence["path"] is not None or evidence["sha256"] is not None:
                    errors.append(f"{label} carries unverified provenance")
                incomplete.append(f"{label} is {evidence['status']}")

        finding_ids: set[str] = set()
        for finding in value["findings"]:
            finding_id = finding["id"]
            if finding_id in finding_ids:
                errors.append(f"duplicate finding ID: {finding_id}")
            finding_ids.add(finding_id)
            severity = finding["severity"]
            status = finding["status"]
            if severity in {"critical", "high"} and status not in CLOSED:
                incomplete.append(f"{finding_id}: {severity}/{status}")
            if severity == "medium" and status not in MEDIUM_ACCEPTABLE:
                incomplete.append(f"{finding_id}: medium/{status}")

            for reference in finding["proof"] + finding["retestEvidence"]:
                try:
                    verify_reference(reference, evidence_root, args.verify_files)
                except GateError as error:
                    errors.append(f"{finding_id}: {error}")

            if status == "verified":
                if not valid_commit(finding["fixCommit"]):
                    errors.append(f"{finding_id}: verified finding lacks a valid fix commit")
                elif args.verify_files and valid_commit(rc_commit):
                    try:
                        require_commit(root, finding["fixCommit"], f"{finding_id} fix commit")
                        require_ancestor(
                            root,
                            finding["fixCommit"],
                            rc_commit,
                            f"{finding_id} fix commit",
                        )
                    except GateError as error:
                        errors.append(str(error))
                if not finding["regressionTest"] or not finding["proof"] or not finding["retestEvidence"]:
                    errors.append(f"{finding_id}: verified finding lacks proof/regression/retest evidence")
                if finding["riskAcceptance"] is not None:
                    errors.append(f"{finding_id}: verified finding must not retain risk acceptance")
            elif status == "outOfScope":
                if not finding["proof"]:
                    errors.append(f"{finding_id}: out-of-scope finding lacks proof")
            elif status == "riskAccepted":
                risk = finding["riskAcceptance"]
                if severity != "medium" or not isinstance(risk, dict) or set(risk) != RISK_KEYS:
                    errors.append(f"{finding_id}: invalid Medium risk acceptance")
                else:
                    if not all(isinstance(risk[key], str) and risk[key] for key in RISK_KEYS):
                        errors.append(f"{finding_id}: incomplete risk acceptance")
                    else:
                        try:
                            expires = date.fromisoformat(risk["expiresAt"])
                        except ValueError:
                            errors.append(f"{finding_id}: invalid risk-acceptance expiry")
                        else:
                            if expires <= as_of:
                                errors.append(f"{finding_id}: risk acceptance expired")
            elif finding["riskAcceptance"] is not None:
                errors.append(f"{finding_id}: risk acceptance is allowed only for Medium/riskAccepted")

        if errors:
            raise GateError("audit closure is malformed:\n- " + "\n- ".join(errors))
        if incomplete:
            if not args.allow_pending:
                raise GateError("audit closure failed:\n- " + "\n- ".join(incomplete))
            if value["decision"] != "noGo" or not value["blockers"]:
                raise GateError("incomplete audit evidence must remain an explicit No-Go with blockers")
            print(f"Audit closure structure is valid and truthfully No-Go ({len(incomplete)} blockers).")
            return 0
        if value["decision"] != "go" or value["blockers"]:
            raise GateError("closed audit evidence requires decision=go and no blockers")
        print("Security audit closure passed.")
        return 0
    except (GateError, OSError, KeyError, TypeError, ValueError) as error:
        return main_error(error)


if __name__ == "__main__":
    raise SystemExit(main())
