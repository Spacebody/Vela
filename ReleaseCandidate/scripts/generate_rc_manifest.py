#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

from _common import (
    GateError,
    checked_evidence,
    git_output,
    load_json,
    main_error,
    parse_semver,
    reject_forbidden_text,
    sha256,
    valid_sha256,
    validate_build_number,
    validate_schema,
    write_immutable_json,
)


GATE_IDS = {
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


def run_validator(script: str, *arguments: str) -> None:
    command = (sys.executable, str(Path(__file__).resolve().parent / script), *arguments)
    result = subprocess.run(command, text=True, capture_output=True)
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "validator failed"
        raise GateError(f"{script}: {detail}")


def require_external_candidate_evidence(
    root: Path, evidence_root: Path, path: Path, label: str
) -> None:
    try:
        evidence_root.relative_to(root)
    except ValueError:
        pass
    else:
        raise GateError("candidate evidence root must be outside the tagged repository")
    try:
        path.resolve().relative_to(evidence_root)
    except ValueError as error:
        raise GateError(f"{label} must be inside the protected candidate evidence root") from error


def record(path: Path) -> dict:
    if Path(path.name).name != path.name:
        raise GateError(f"artifact filename is unsafe: {path}")
    return {"filename": path.name, "sha256": sha256(path), "size": path.stat().st_size}


def checksum_rows(path: Path) -> dict[str, str]:
    rows: dict[str, str] = {}
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line:
            continue
        pieces = line.split("  ", 1)
        if len(pieces) != 2 or not valid_sha256(pieces[0]) or Path(pieces[1]).name != pieces[1]:
            raise GateError(f"invalid checksum row at line {line_number}")
        if pieces[1] in rows:
            raise GateError(f"duplicate checksum filename: {pieces[1]}")
        rows[pieces[1]] = pieces[0]
    return rows


def validate_external(
    value: dict,
    *,
    marketing_version: str,
    candidate_version: str,
    prerelease_label: str | None,
    build: int,
    tag: str,
    commit: str,
    architecture_sha: str,
    dmg: Path,
    appcast: Path,
) -> tuple[dict, dict, dict]:
    app = value.get("app", {})
    source = value.get("source", {})
    build_data = value.get("build", {})
    if value.get("schemaVersion") != 1 or value.get("manifestKind") != "external":
        raise GateError("release manifest is not an external schemaVersion 1 manifest")
    _, prerelease = parse_semver(candidate_version)
    expected_channel = "beta" if prerelease is not None else "stable"
    expected_label = prerelease_label
    expected_app = {
        "version": marketing_version,
        "build": build,
        "channel": expected_channel,
        "prereleaseLabel": expected_label,
    }
    for key, expected in expected_app.items():
        if app.get(key) != expected:
            raise GateError(f"external release manifest app.{key} differs from the candidate")
    if source.get("commit") != commit or source.get("tag") != tag:
        raise GateError("external release manifest source differs from the exact candidate tag")
    if source.get("architectureFreezeSHA256") != architecture_sha:
        raise GateError("external release manifest architecture-freeze SHA-256 differs")
    if build_data.get("sourceDirty") is not False:
        raise GateError("external release manifest reports dirty source")
    for name, path in (("dmg", dmg), ("appcast", appcast)):
        artifact = value.get("artifacts", {}).get(name, {})
        if artifact.get("filename") != path.name or artifact.get("sha256") != sha256(path):
            raise GateError(f"external release manifest {name} does not match the supplied artifact")
    trust = value.get("trust", {})
    if not valid_sha256(trust.get("signingCertificateSHA256")):
        raise GateError("external release manifest lacks a valid signing certificate SHA-256")
    notarization = value.get("notarization", {})
    for kind in ("app", "dmg"):
        summary = notarization.get(kind)
        if not isinstance(summary, dict) or summary.get("status") != "Accepted" or not summary.get("submissionID"):
            raise GateError(f"external release manifest lacks accepted {kind} notarization")
    toolchain = value.get("toolchain")
    if not isinstance(toolchain, dict) or not toolchain:
        raise GateError("external release manifest lacks toolchain provenance")
    return trust, notarization, toolchain


def attestation(required_subjects: dict[str, str]) -> dict:
    policy = {
        "workflowPath": ".github/workflows/release.yml",
        "environment": "production",
        "verificationRepository": "Spacebody/Vela",
        "requiredPermissions": ["id-token:write", "attestations:write", "artifact-metadata:write"],
    }
    return {
        "status": "pendingExternal",
        "evidence": None,
        "subjects": [
            {"filename": filename, "sha256": digest}
            for filename, digest in sorted(required_subjects.items())
        ],
        "policy": policy,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate an immutable Vela RC provenance manifest")
    parser.add_argument("--repository-root", default=".")
    parser.add_argument("--evidence-root")
    parser.add_argument("--version", required=True, help="bundle marketing version, for example 1.0.0")
    parser.add_argument("--candidate-version", required=True, help="logical version, for example 1.0.0-rc.1")
    parser.add_argument("--build", type=int, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--prerelease-label")
    parser.add_argument("--public-contract", required=True)
    parser.add_argument("--architecture-freeze", required=True)
    parser.add_argument("--documentation-manifest", required=True)
    parser.add_argument("--privacy-manifest", required=True)
    parser.add_argument("--migration", required=True)
    parser.add_argument("--audit", required=True)
    parser.add_argument("--audit-summary", required=True)
    parser.add_argument("--known-limitations", required=True)
    parser.add_argument("--go-no-go", required=True)
    parser.add_argument("--release-manifest", required=True)
    parser.add_argument("--dmg", required=True)
    parser.add_argument("--sbom", required=True)
    parser.add_argument("--appcast", required=True)
    parser.add_argument("--checksums", required=True)
    parser.add_argument("--require-release-ready", action="store_true")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        root = Path(args.repository_root).resolve()
        base, prerelease = parse_semver(args.candidate_version)
        if base != args.version:
            raise GateError("candidate SemVer base differs from the marketing version")
        logical_channel = "rc" if prerelease is not None else "stable"
        if logical_channel == "rc" and (
            prerelease is None or re.fullmatch(r"rc\.[1-9][0-9]*", prerelease) is None
        ):
            raise GateError("candidate prerelease must be rc.N")
        if logical_channel == "rc":
            sequence = prerelease.split(".", 1)[1]
            if args.prerelease_label != f"RC {sequence}":
                raise GateError(f"RC prerelease label must be exactly 'RC {sequence}'")
        elif args.prerelease_label is not None:
            raise GateError("Stable candidate must not have a prerelease label")
        if args.tag != f"v{args.candidate_version}":
            raise GateError("tag differs from the candidate version")
        validate_build_number(args.build)
        dirty = bool(git_output(root, "status", "--porcelain"))
        if dirty:
            raise GateError("refusing RC manifest generation from dirty source")
        commit = git_output(root, "rev-parse", "HEAD")
        tag_ref = f"refs/tags/{args.tag}"
        if git_output(root, "cat-file", "-t", tag_ref) != "tag":
            raise GateError("candidate tag must be annotated")
        tag_commit = git_output(root, "rev-parse", f"{tag_ref}^{{commit}}")
        if tag_commit != commit:
            raise GateError("candidate tag does not point at HEAD")
        git_output(root, "verify-tag", tag_ref)

        paths = {
            "publicContract": Path(args.public_contract),
            "architecture": Path(args.architecture_freeze),
            "documentation": Path(args.documentation_manifest),
            "privacy": Path(args.privacy_manifest),
            "migrationGuarantee": Path(args.migration),
            "auditClosure": Path(args.audit),
            "auditSummary": Path(args.audit_summary),
            "knownLimitations": Path(args.known_limitations),
            "goNoGo": Path(args.go_no_go),
            "releaseManifest": Path(args.release_manifest),
            "dmg": Path(args.dmg),
            "sbom": Path(args.sbom),
            "appcast": Path(args.appcast),
            "checksums": Path(args.checksums),
        }
        evidence_root = Path(args.evidence_root).resolve() if args.evidence_root else root
        if args.require_release_ready:
            if not args.evidence_root:
                raise GateError("--require-release-ready requires a protected external --evidence-root")
            raw_evidence_root = Path(args.evidence_root)
            if not raw_evidence_root.is_dir() or raw_evidence_root.is_symlink():
                raise GateError("candidate evidence root is missing or unsafe")
            for candidate in raw_evidence_root.rglob("*"):
                if candidate.is_symlink():
                    raise GateError(f"candidate evidence root contains a symlink: {candidate}")
            require_external_candidate_evidence(
                root, evidence_root, paths["auditClosure"], "audit closure"
            )
            require_external_candidate_evidence(
                root, evidence_root, paths["auditSummary"], "audit summary"
            )
            require_external_candidate_evidence(
                root, evidence_root, paths["goNoGo"], "Go/No-Go packet"
            )
        records = {
            name: record(path)
            for name, path in paths.items()
            if name not in {"auditClosure", "goNoGo"}
        }
        expected_dmg = f"Vela-{args.candidate_version}-arm64.dmg"
        if paths["dmg"].name != expected_dmg:
            raise GateError(f"RC DMG must be named {expected_dmg}")

        migration = load_json(paths["migrationGuarantee"], label="migration guarantee")
        audit = load_json(paths["auditClosure"], label="audit closure")
        limitations = load_json(paths["knownLimitations"], label="known limitations")
        decision = load_json(paths["goNoGo"], label="Go/No-Go packet")
        validate_schema(migration, "migration-guarantee.schema.json")
        validate_schema(audit, "audit-closure.schema.json")
        validate_schema(limitations, "known-limitations.schema.json")
        validate_schema(decision, "go-no-go.schema.json")
        if limitations["version"] != args.version:
            raise GateError("Known Limitations version differs from the candidate")
        if decision["candidate"] != {"version": args.candidate_version, "build": args.build, "commit": commit}:
            raise GateError("Go/No-Go packet does not bind the exact candidate")
        gate_map = {item["id"]: item["status"] for item in decision["gates"]}
        if set(gate_map) != GATE_IDS or len(decision["gates"]) != len(GATE_IDS):
            raise GateError("Go/No-Go packet gate set is incomplete")

        migration_arguments = [
            str(paths["migrationGuarantee"]),
            "--repository-root",
            str(root),
            "--verify-files",
        ]
        audit_arguments = [
            str(paths["auditClosure"]),
            "--repository-root",
            str(root),
            "--evidence-root",
            str(evidence_root),
            "--verify-files",
            "--expected-commit",
            commit,
        ]
        if not args.require_release_ready:
            migration_arguments.append("--allow-pending")
            audit_arguments.append("--allow-pending")
        run_validator("validate_migration_guarantee.py", *migration_arguments)
        run_validator("validate_audit_closure.py", *audit_arguments)
        public_summary = audit["publicSummary"]
        if public_summary["status"] != "verified":
            raise GateError("audit closure must bind a verified public audit summary")
        summary_path = checked_evidence(
            evidence_root, public_summary["path"], public_summary["sha256"]
        )
        if summary_path.resolve() != paths["auditSummary"].resolve():
            raise GateError("--audit-summary differs from audit closure publicSummary evidence")
        run_validator(
            "validate_known_limitations.py",
            str(paths["knownLimitations"]),
            "--version",
            args.version,
            "--public-contract",
            str(paths["publicContract"]),
        )
        decision_arguments = [
            str(paths["goNoGo"]),
            "--repository-root",
            str(root),
            "--evidence-root",
            str(evidence_root),
            "--verify-files",
            "--candidate-version",
            args.candidate_version,
            "--build",
            str(args.build),
            "--commit",
            commit,
        ]
        if args.require_release_ready:
            decision_arguments.append("--pre-artifact")
        run_validator("validate_go_no_go.py", *decision_arguments)

        if (gate_map["migration"] == "pass") != (migration["decision"] == "go"):
            raise GateError("migration gate status contradicts the migration guarantee decision")
        if (gate_map["securityAudit"] == "pass") != (audit["decision"] == "go"):
            raise GateError("securityAudit gate status contradicts the audit-closure decision")

        if gate_map["artifact"] != "pending" or decision["decision"] not in {"noGo", "pending"}:
            raise GateError(
                "embedded pendingExternal attestation requires artifact=pending and a non-Go decision"
            )

        architecture_sha = records["architecture"]["sha256"]
        external = load_json(paths["releaseManifest"], label="external release manifest")
        trust, notarization, toolchain = validate_external(
            external,
            marketing_version=args.version,
            candidate_version=args.candidate_version,
            prerelease_label=args.prerelease_label,
            build=args.build,
            tag=args.tag,
            commit=commit,
            architecture_sha=architecture_sha,
            dmg=paths["dmg"],
            appcast=paths["appcast"],
        )

        checksum_map = checksum_rows(paths["checksums"])
        for name in ("releaseManifest", "dmg", "sbom", "appcast"):
            artifact = records[name]
            if checksum_map.get(artifact["filename"]) != artifact["sha256"]:
                raise GateError(f"base checksums do not verify {artifact['filename']}")

        attest = attestation({
            records["dmg"]["filename"]: records["dmg"]["sha256"],
            records["sbom"]["filename"]: records["sbom"]["sha256"],
        })
        github_actions = os.environ.get("GITHUB_ACTIONS") == "true"
        if github_actions:
            if os.environ.get("GITHUB_REPOSITORY") != "Spacebody/Vela":
                raise GateError("GitHub release provenance requires repository Spacebody/Vela")
            if not os.environ.get("GITHUB_RUN_ID"):
                raise GateError("GitHub release provenance requires GITHUB_RUN_ID")
            if os.environ.get("RUNNER_ARCH") != "ARM64" or os.environ.get("RUNNER_OS") != "macOS":
                raise GateError("GitHub release provenance requires a macOS ARM64 runner")
            workflow_ref = os.environ.get("GITHUB_WORKFLOW_REF", "")
            expected_workflow_ref = f"Spacebody/Vela/.github/workflows/release.yml@refs/tags/{args.tag}"
            if workflow_ref != expected_workflow_ref:
                raise GateError("GitHub release provenance is not running the exact tagged release workflow")
            if os.environ.get("GITHUB_REF") != f"refs/tags/{args.tag}" or os.environ.get("GITHUB_SHA") != commit:
                raise GateError("GitHub release provenance does not bind the exact source tag and commit")
            if os.environ.get("GITHUB_REF_PROTECTED") != "true":
                raise GateError("GitHub release provenance requires a protected candidate tag")
        manifest = {
            "schemaVersion": 1,
            "candidate": {
                "version": args.candidate_version,
                "marketingVersion": args.version,
                "build": args.build,
                "channel": logical_channel,
                "appUpdateChannel": "beta" if logical_channel == "rc" else "stable",
                "prereleaseLabel": args.prerelease_label,
            },
            "source": {"commit": commit, "tag": args.tag, "dirty": False},
            "freeze": {name: records[name] for name in ("publicContract", "architecture", "documentation", "privacy")},
            "quality": gate_map,
            "artifacts": {
                name: records[name]
                for name in (
                    "releaseManifest", "dmg", "sbom", "appcast", "checksums",
                    "migrationGuarantee", "auditSummary", "knownLimitations",
                )
            },
            "signing": {
                "certificateSHA256": trust["signingCertificateSHA256"],
                "appNotary": notarization["app"],
                "dmgNotary": notarization["dmg"],
                "bundleVerificationRequired": True,
            },
            "provenance": {
                "toolchain": toolchain,
                "workflow": {
                    "repository": "Spacebody/Vela" if github_actions else None,
                    "runID": os.environ.get("GITHUB_RUN_ID") if github_actions else None,
                    "runnerClass": "github-actions/macos/arm64" if github_actions else "local/macos/arm64",
                },
                "attestation": attest,
            },
        }
        validate_schema(manifest, "release-candidate-manifest.schema.json")
        reject_forbidden_text(manifest, label="RC manifest")
        if args.require_release_ready:
            non_artifact = {
                name: status
                for name, status in gate_map.items()
                if name != "artifact" and status != "pass"
            }
            if migration["decision"] != "go" or audit["decision"] != "go" or non_artifact:
                raise GateError(f"local release stage has incomplete non-artifact gates: {non_artifact}")
        output = Path(args.output)
        write_immutable_json(output, manifest)
        print(output)
        return 0
    except (GateError, OSError, KeyError, TypeError, ValueError) as error:
        return main_error(error)


if __name__ == "__main__":
    raise SystemExit(main())
