#!/usr/bin/env python3
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

from _common import (
    GateError,
    checked_evidence,
    load_json,
    main_error,
    reject_forbidden_text,
    sha256,
    validate_schema,
    write_immutable_json,
)


def run_validator(script: str, *arguments: str) -> None:
    command = (sys.executable, str(Path(__file__).resolve().parent / script), *arguments)
    result = subprocess.run(command, text=True, capture_output=True)
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "validator failed"
        raise GateError(f"{script}: {detail}")


def require_record(record: dict, path: Path, label: str) -> None:
    if (
        record["filename"] != path.name
        or record["size"] != path.stat().st_size
        or record["sha256"] != sha256(path)
    ):
        raise GateError(f"{label} differs from the immutable RC manifest record")


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate a non-promotional V1 readiness summary")
    parser.add_argument("--rc", required=True)
    parser.add_argument("--go-no-go", required=True)
    parser.add_argument("--migration", required=True)
    parser.add_argument("--audit", required=True)
    parser.add_argument("--audit-summary", required=True)
    parser.add_argument("--known-limitations", required=True)
    parser.add_argument("--repository-root", default=".")
    parser.add_argument("--evidence-root")
    parser.add_argument("--public-contract")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        rc = load_json(Path(args.rc), label="RC manifest")
        decision = load_json(Path(args.go_no_go), label="Go/No-Go packet")
        migration = load_json(Path(args.migration), label="migration guarantee")
        audit = load_json(Path(args.audit), label="audit closure")
        limitations = load_json(Path(args.known_limitations), label="known limitations")
        validate_schema(rc, "release-candidate-manifest.schema.json")
        validate_schema(decision, "go-no-go.schema.json")
        validate_schema(migration, "migration-guarantee.schema.json")
        validate_schema(audit, "audit-closure.schema.json")
        validate_schema(limitations, "known-limitations.schema.json")

        candidate = rc["candidate"]
        if decision["candidate"] != {
            "version": candidate["version"],
            "build": candidate["build"],
            "commit": rc["source"]["commit"],
        }:
            raise GateError("Go/No-Go packet differs from the RC manifest")
        decision_gates = {gate["id"]: gate["status"] for gate in decision["gates"]}
        if decision_gates != rc["quality"] or len(decision["gates"]) != len(rc["quality"]):
            raise GateError("Go/No-Go gate statuses differ from the RC manifest")
        if (rc["quality"]["migration"] == "pass") != (migration["decision"] == "go"):
            raise GateError("migration status differs between evidence and the RC manifest")
        if (rc["quality"]["securityAudit"] == "pass") != (audit["decision"] == "go"):
            raise GateError("audit status differs between evidence and the RC manifest")
        root = Path(args.repository_root).resolve()
        if args.evidence_root and (
            not Path(args.evidence_root).is_dir() or Path(args.evidence_root).is_symlink()
        ):
            raise GateError("evidence root is missing or unsafe")
        if args.evidence_root:
            for candidate_path in Path(args.evidence_root).rglob("*"):
                if candidate_path.is_symlink():
                    raise GateError(f"evidence root contains a symlink: {candidate_path}")
        evidence_root = Path(args.evidence_root).resolve() if args.evidence_root else root
        public_contract = Path(args.public_contract) if args.public_contract else (
            root / "Contracts/v1/public-contract-freeze.json"
        )
        require_record(rc["freeze"]["publicContract"], public_contract, "public contract")
        for record_name, raw_path, label in (
            ("migrationGuarantee", args.migration, "migration guarantee"),
            ("auditSummary", args.audit_summary, "audit summary"),
            ("knownLimitations", args.known_limitations, "known limitations"),
        ):
            require_record(rc["artifacts"][record_name], Path(raw_path), label)
        run_validator("validate_release_candidate.py", str(Path(args.rc)), "--stage", "structural")
        run_validator(
            "validate_migration_guarantee.py",
            str(Path(args.migration)),
            "--allow-pending",
            "--repository-root",
            str(root),
            "--verify-files",
        )
        run_validator(
            "validate_audit_closure.py",
            str(Path(args.audit)),
            "--allow-pending",
            "--repository-root",
            str(root),
            "--evidence-root",
            str(evidence_root),
            "--verify-files",
            "--expected-commit",
            rc["source"]["commit"],
        )
        public_summary = audit["publicSummary"]
        if public_summary["status"] != "verified":
            raise GateError("audit closure must bind a verified public audit summary")
        summary_path = checked_evidence(
            evidence_root, public_summary["path"], public_summary["sha256"]
        )
        if summary_path.resolve() != Path(args.audit_summary).resolve():
            raise GateError("audit summary differs from audit closure publicSummary evidence")
        run_validator(
            "validate_known_limitations.py",
            str(Path(args.known_limitations)),
            "--version",
            candidate["marketingVersion"],
            "--public-contract",
            str(public_contract),
        )
        decision_arguments = [
            str(Path(args.go_no_go)),
            "--repository-root",
            str(root),
            "--evidence-root",
            str(evidence_root),
            "--verify-files",
            "--candidate-version",
            candidate["version"],
            "--build",
            str(candidate["build"]),
            "--commit",
            rc["source"]["commit"],
        ]
        run_validator("validate_go_no_go.py", *decision_arguments)
        if (
            rc["quality"]["artifact"] == "pending"
            and all(
                status == "pass"
                for gate, status in rc["quality"].items()
                if gate != "artifact"
            )
        ):
            run_validator("validate_go_no_go.py", *decision_arguments, "--pre-artifact")
        blockers: list[str] = []
        for gate, status in rc["quality"].items():
            if status != "pass":
                blockers.append(f"gate {gate}: {status}")
        if migration["decision"] != "go":
            blockers.append(f"migration decision: {migration['decision']}")
        if audit["decision"] != "go":
            blockers.append(f"audit decision: {audit['decision']}")
        attestation_status = rc["provenance"]["attestation"]["status"]
        blockers.append(f"attestation: {attestation_status}; requires independent gh verification")
        if decision["decision"] != "go":
            blockers.append(f"decision: {decision['decision']}")

        final_decision = "go" if not blockers else "noGo"
        report = {
            "schemaVersion": 2,
            "candidate": {
                "version": candidate["version"],
                "build": candidate["build"],
                "commit": rc["source"]["commit"],
            },
            "decision": final_decision,
            "gates": [
                {"id": gate, "status": status}
                for gate, status in sorted(rc["quality"].items())
            ],
            "migration": {
                "decision": migration["decision"],
                "sources": {
                    source["version"]: source["status"]
                    for source in migration["sources"]
                },
                "stores": {
                    store["id"]: store["status"]
                    for store in migration["stores"]
                },
            },
            "audit": {
                "decision": audit["decision"],
                "criticalHighOpenCount": sum(
                    1
                    for finding in audit["findings"]
                    if finding["severity"] in {"critical", "high"}
                    and finding["status"] not in {"verified", "outOfScope"}
                ),
            },
            "knownLimitations": [item["id"] for item in limitations["limitations"]],
            "blockers": blockers,
        }
        validate_schema(report, "readiness-report.schema.json")
        reject_forbidden_text(report, label="V1 readiness report")
        write_immutable_json(Path(args.output), report)
        print(f"{args.output}: {final_decision} ({len(blockers)} blocker(s))")
        return 0
    except (GateError, OSError, KeyError, TypeError, ValueError) as error:
        return main_error(error)


if __name__ == "__main__":
    raise SystemExit(main())
