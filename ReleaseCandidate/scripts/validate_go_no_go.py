#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
from pathlib import Path

from _common import (
    GateError,
    checked_evidence,
    load_json,
    main_error,
    parse_semver,
    reject_forbidden_text,
    valid_commit,
    valid_sha256,
    validate_build_number,
    validate_schema,
)


REQUIRED_GATES = {
    "stopShip",
    "contracts",
    "migration",
    "securityAudit",
    "soak",
    "performance",
    "accessibilityPrivacy",
    "installation",
    "artifact",
    "supportIncident",
}
REQUIRED_APPROVALS = {
    "Release",
    "Security",
    "Reliability",
    "Product",
    "Support",
    "AccessibilityLocalization",
}


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate the Vela V1 Go/No-Go decision packet")
    parser.add_argument("manifest")
    parser.add_argument("--expect", choices=["go", "noGo", "pending"])
    parser.add_argument("--repository-root", default=".")
    parser.add_argument("--evidence-root")
    parser.add_argument("--verify-files", action="store_true")
    parser.add_argument("--candidate-version")
    parser.add_argument("--build", type=int)
    parser.add_argument("--commit")
    parser.add_argument("--artifact-sha256")
    parser.add_argument("--candidate-stage", action="store_true")
    parser.add_argument("--pre-artifact", action="store_true")
    args = parser.parse_args()
    try:
        value = load_json(Path(args.manifest), label="Go/No-Go packet")
        validate_schema(value, "go-no-go.schema.json")
        reject_forbidden_text(value, label="Go/No-Go packet")
        gates = value["gates"]
        ids = [gate["id"] for gate in gates]
        if set(ids) != REQUIRED_GATES or len(ids) != len(REQUIRED_GATES):
            raise GateError("Go/No-Go packet must contain each required gate exactly once")
        if args.expect and value["decision"] != args.expect:
            raise GateError(f"expected decision {args.expect}, got {value['decision']}")

        candidate = value["candidate"]
        candidate_values = (candidate["version"], candidate["build"], candidate["commit"])
        if any(item is not None for item in candidate_values):
            if (
                not isinstance(candidate["version"], str)
                or not isinstance(candidate["build"], int)
                or not valid_commit(candidate["commit"])
            ):
                raise GateError("candidate identity must be entirely null or fully concrete")
            _, prerelease = parse_semver(candidate["version"])
            if prerelease is not None and re.fullmatch(r"rc\.[1-9][0-9]*", prerelease) is None:
                raise GateError("candidate prerelease must use rc.N")
            validate_build_number(candidate["build"])
        expected = {
            "version": args.candidate_version,
            "build": args.build,
            "commit": args.commit,
        }
        for key, wanted in expected.items():
            if wanted is not None and candidate[key] != wanted:
                raise GateError(f"Go/No-Go candidate {key} differs from release preflight")

        root = Path(args.evidence_root) if args.evidence_root else Path(args.repository_root)
        for gate in gates:
            if gate["status"] == "pass" and not gate["evidence"]:
                raise GateError(f"passed gate has no evidence: {gate['id']}")
            for reference in gate["evidence"]:
                if not valid_sha256(reference["sha256"]):
                    raise GateError(f"gate evidence SHA-256 is invalid: {gate['id']}")
                if args.verify_files:
                    checked_evidence(root, reference["path"], reference["sha256"])

        if args.candidate_stage and args.pre_artifact:
            raise GateError("--candidate-stage and --pre-artifact are mutually exclusive")
        if args.candidate_stage:
            if not isinstance(candidate["version"], str) or not isinstance(candidate["build"], int) or not valid_commit(candidate["commit"]):
                raise GateError("candidate-stage packet must bind a concrete candidate")
            prebuild_gates = {
                "stopShip",
                "contracts",
                "migration",
                "securityAudit",
                "supportIncident",
            }
            postbuild_gates = REQUIRED_GATES - prebuild_gates
            incomplete_prebuild = {
                gate["id"]: gate["status"]
                for gate in gates
                if gate["id"] in prebuild_gates and gate["status"] != "pass"
            }
            invalid_postbuild = {
                gate["id"]: gate["status"]
                for gate in gates
                if gate["id"] in postbuild_gates and gate["status"] != "pending"
            }
            postbuild_evidence = [
                gate["id"]
                for gate in gates
                if gate["id"] in postbuild_gates and gate["evidence"]
            ]
            if incomplete_prebuild:
                raise GateError(f"candidate-stage prebuild gates are incomplete: {incomplete_prebuild}")
            if invalid_postbuild:
                raise GateError(f"candidate-stage postbuild gates must remain pending: {invalid_postbuild}")
            if postbuild_evidence:
                raise GateError(
                    "candidate-stage postbuild gates cannot claim pre-artifact evidence: "
                    + ", ".join(sorted(postbuild_evidence))
                )
            if value["decision"] not in {"noGo", "pending"}:
                raise GateError("candidate-stage packet must not claim Go")
        elif args.pre_artifact:
            if not isinstance(candidate["version"], str) or not isinstance(candidate["build"], int) or not valid_commit(candidate["commit"]):
                raise GateError("pre-artifact packet must bind a concrete candidate")
            non_artifact = {
                gate["id"]: gate["status"]
                for gate in gates
                if gate["id"] != "artifact" and gate["status"] != "pass"
            }
            artifact_status = next(gate["status"] for gate in gates if gate["id"] == "artifact")
            if non_artifact:
                raise GateError(f"pre-artifact gates are incomplete: {non_artifact}")
            if artifact_status != "pending":
                raise GateError("pre-artifact packet requires artifact=pending")
            if value["decision"] not in {"noGo", "pending"}:
                raise GateError("pre-artifact packet must not claim Go")
        elif value["decision"] == "go":
            if not isinstance(candidate["version"], str) or not valid_commit(candidate["commit"]):
                raise GateError("Go decision requires a concrete candidate version and commit")
            if not isinstance(candidate["build"], int):
                raise GateError("Go decision requires a concrete candidate build")
            validate_build_number(candidate["build"])
            non_pass = {gate["id"]: gate["status"] for gate in gates if gate["status"] != "pass"}
            if non_pass:
                raise GateError(f"Go decision contains non-pass gates: {non_pass}")
            if not valid_sha256(args.artifact_sha256):
                raise GateError("Go validation requires the exact candidate artifact SHA-256")
            roles = [approval["role"] for approval in value["approvals"]]
            if set(roles) != REQUIRED_APPROVALS or len(roles) != len(REQUIRED_APPROVALS):
                raise GateError("Go decision lacks the exact accountable approval set")
            for approval in value["approvals"]:
                if approval["candidateVersion"] != candidate["version"]:
                    raise GateError(f"approval does not bind candidate version: {approval['role']}")
                if approval["candidateBuild"] != candidate["build"]:
                    raise GateError(f"approval does not bind candidate build: {approval['role']}")
                if approval["candidateCommit"] != candidate["commit"]:
                    raise GateError(f"approval does not bind candidate commit: {approval['role']}")
                if approval["artifactSHA256"] != args.artifact_sha256:
                    raise GateError(f"approval does not bind the exact candidate artifact: {approval['role']}")
        elif not value["decisionReason"]:
            raise GateError("No-Go/Pending decision requires a reason")

        print(f"Go/No-Go packet validation passed: {value['decision']}")
        return 0
    except (GateError, OSError, KeyError, TypeError, ValueError) as error:
        return main_error(error)


if __name__ == "__main__":
    raise SystemExit(main())
