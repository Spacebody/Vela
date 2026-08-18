#!/usr/bin/env python3
"""Close Vela promotion from exact, typed, independently retained evidence."""

from __future__ import annotations

import argparse
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any

from _common import GateError, main_error, valid_sha256, validate_schema
from candidate_stage_common import (
    JSON_LIMIT,
    candidate_contract,
    decode_json,
    read_stage_file,
    reject_placeholders,
    secure_directory,
    secure_private_evidence_root,
    write_private_json,
)


SCRIPT_DIR = Path(__file__).resolve().parent
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
APPROVAL_ROLES = {
    "Release",
    "Security",
    "Reliability",
    "Product",
    "Support",
    "AccessibilityLocalization",
}
BUNDLE_LIMIT = 32 * 1024 * 1024


def run_validator(script: str, *arguments: str) -> None:
    result = subprocess.run(
        (sys.executable, str(SCRIPT_DIR / script), *arguments),
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "validator failed"
        raise GateError(f"{script}: {detail}")


def run_offline_attestation_verifier(
    *,
    manifest: Path,
    public_root: Path,
    subject_checksums: Path,
    bundle: Path,
    bundle_sha256: str,
    trusted_root: Path,
    trusted_root_sha256: str,
) -> None:
    result = subprocess.run(
        (
            str(SCRIPT_DIR / "verify_rc_attestations.sh"),
            "--manifest",
            str(manifest),
            "--artifacts-dir",
            str(public_root),
            "--subject-checksums",
            str(subject_checksums),
            "--bundle",
            str(bundle),
            "--expected-bundle-sha256",
            bundle_sha256,
            "--trusted-root",
            str(trusted_root),
            "--expected-trusted-root-sha256",
            trusted_root_sha256,
            "--verify-only",
        ),
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "offline verification failed"
        raise GateError(f"offline GitHub attestation bundle verification failed: {detail}")


def roots_overlap(first: Path, second: Path) -> bool:
    return first == second or first in second.parents or second in first.parents


def require_disjoint_roots(roots: tuple[tuple[str, Path], ...]) -> None:
    for index, (first_label, first) in enumerate(roots):
        for second_label, second in roots[index + 1 :]:
            if roots_overlap(first, second):
                raise GateError(
                    f"{first_label} and {second_label} must be separate, non-overlapping roots"
                )


def parse_timestamp(value: Any, *, label: str) -> datetime:
    if not isinstance(value, str):
        raise GateError(f"{label} must be a timezone-aware date-time")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise GateError(f"{label} must be a timezone-aware date-time") from error
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise GateError(f"{label} must include a timezone")
    return parsed.astimezone(timezone.utc)


def read_json_input(
    root: Path,
    raw_path: str,
    *,
    label: str,
    root_name: str,
) -> tuple[dict[str, Any], dict[str, Any], Path]:
    data, record = read_stage_file(root, raw_path, label=label, maximum_bytes=JSON_LIMIT)
    value = decode_json(data, label=label)
    return value, {"root": root_name, **record}, root / record["path"]


def read_allowed_file(
    raw_path: str,
    *,
    evidence_root: Path,
    public_root: Path,
    label: str,
) -> tuple[bytes, dict[str, Any], Path]:
    supplied = Path(raw_path)
    candidates: list[tuple[str, Path, Path]] = []
    if supplied.is_absolute():
        resolved = supplied.resolve(strict=True)
        for root_name, root in (
            ("publicArtifacts", public_root),
            ("evidence", evidence_root),
        ):
            try:
                resolved.relative_to(root)
            except ValueError:
                continue
            candidates.append((root_name, root, supplied))
    else:
        for root_name, root in (
            ("publicArtifacts", public_root),
            ("evidence", evidence_root),
        ):
            candidate = root / supplied
            if candidate.exists() or candidate.is_symlink():
                candidates.append((root_name, root, candidate))
    if not candidates:
        raise GateError(f"{label} must be inside the evidence or public-artifacts root")
    if len(candidates) > 1:
        raise GateError(f"{label} path is ambiguous between protected roots")
    root_name, root, path = candidates[0]
    data, record = read_stage_file(root, path, label=label, maximum_bytes=JSON_LIMIT)
    return data, {"root": root_name, **record}, root / record["path"]


def normalized_subject(record: dict[str, Any], *, label: str) -> dict[str, Any]:
    filename = record.get("filename")
    if not isinstance(filename, str) or "\\" in filename:
        raise GateError(f"{label} filename is unsafe")
    pure = PurePosixPath(filename)
    if (
        pure.is_absolute()
        or not pure.parts
        or ".." in pure.parts
        or pure.as_posix() != filename
        or any(ord(character) < 32 or ord(character) == 127 for character in filename)
    ):
        raise GateError(f"{label} filename is unsafe: {filename!r}")
    if not isinstance(record.get("size"), int) or record["size"] <= 0:
        raise GateError(f"{label} size is invalid")
    if not valid_sha256(record.get("sha256")):
        raise GateError(f"{label} SHA-256 is invalid")
    return {
        "filename": filename,
        "sha256": record["sha256"],
        "size": record["size"],
    }


def exact_file(record: dict[str, Any]) -> dict[str, Any]:
    return {key: record[key] for key in ("filename", "sha256", "size")}


def exact_reference(record: dict[str, Any]) -> dict[str, Any]:
    return {"path": record["path"], "sha256": record["sha256"]}


def checksum_rows(data: bytes, *, label: str) -> dict[str, str]:
    try:
        lines = data.decode("utf-8").splitlines()
    except UnicodeError as error:
        raise GateError(f"{label} is not UTF-8") from error
    rows: dict[str, str] = {}
    for line_number, line in enumerate(lines, 1):
        if not line:
            continue
        pieces = line.split("  ", 1)
        if len(pieces) != 2 or not valid_sha256(pieces[0]):
            raise GateError(f"{label} has an invalid row at line {line_number}")
        subject = normalized_subject(
            {"filename": pieces[1], "sha256": pieces[0], "size": 1},
            label=f"{label} row {line_number}",
        )["filename"]
        if subject in rows:
            raise GateError(f"{label} has a duplicate subject: {subject}")
        rows[subject] = pieces[0]
    if not rows:
        raise GateError(f"{label} is empty")
    return rows


def require_identity(value: dict[str, Any], expected: dict[str, Any], *, label: str) -> None:
    for key, wanted in expected.items():
        if value.get(key) != wanted:
            raise GateError(f"{label} {key} differs from the exact promotion candidate")


def require_public_record(public_root: Path, record: dict[str, Any], *, label: str) -> None:
    _, actual = read_stage_file(public_root, record["filename"], label=label)
    if exact_file(actual) != exact_file(record):
        raise GateError(f"{label} bytes differ from the RC manifest")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate an immutable private closure after every Vela promotion proof passes"
    )
    parser.add_argument("--candidate-version", required=True)
    parser.add_argument("--build", required=True, type=int)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--go-no-go", required=True)
    parser.add_argument("--installation-matrix", required=True)
    parser.add_argument("--candidate-stage-evidence", required=True)
    parser.add_argument("--candidate-stage-root", required=True)
    parser.add_argument("--rc-manifest", required=True)
    parser.add_argument("--attestation-verification", required=True)
    parser.add_argument("--attestation-bundle", required=True)
    parser.add_argument("--attestation-trusted-root", required=True)
    parser.add_argument("--subject-checksums", required=True)
    parser.add_argument("--public-artifacts-dir", required=True)
    parser.add_argument("--evidence-root", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    try:
        evidence_root = secure_private_evidence_root(
            args.evidence_root,
            label="promotion evidence root",
        )
        public_root = secure_directory(
            args.public_artifacts_dir,
            label="public artifacts root",
        )
        candidate_stage_root = secure_directory(
            args.candidate_stage_root,
            label="candidate-stage evidence root",
        )
        require_disjoint_roots(
            (
                ("candidate-stage evidence root", candidate_stage_root),
                ("promotion evidence root", evidence_root),
                ("public artifacts root", public_root),
            )
        )

        version = args.candidate_version
        build = args.build
        commit = args.commit
        tag = f"v{version}"
        candidate_contract(version=version, build=build, tag=tag, commit=commit)
        identity = {"version": version, "build": build, "commit": commit}

        go, go_record, go_path = read_json_input(
            evidence_root,
            args.go_no_go,
            label="final Go/No-Go packet",
            root_name="evidence",
        )
        matrix, matrix_record, matrix_path = read_json_input(
            evidence_root,
            args.installation_matrix,
            label="final installation matrix",
            root_name="evidence",
        )
        candidate_stage, stage_record, stage_path = read_json_input(
            candidate_stage_root,
            args.candidate_stage_evidence,
            label="candidate-stage evidence",
            root_name="candidateStage",
        )
        attestation, attestation_record, attestation_path = read_json_input(
            evidence_root,
            args.attestation_verification,
            label="attestation verification report",
            root_name="evidence",
        )
        _, bundle_record = read_stage_file(
            evidence_root,
            args.attestation_bundle,
            label="offline GitHub attestation bundle",
            maximum_bytes=BUNDLE_LIMIT,
        )
        bundle_record = {"root": "evidence", **bundle_record}
        bundle_path = evidence_root / bundle_record["path"]
        _, trusted_root_record = read_stage_file(
            evidence_root,
            args.attestation_trusted_root,
            label="offline GitHub trusted root",
            maximum_bytes=BUNDLE_LIMIT,
        )
        trusted_root_record = {"root": "evidence", **trusted_root_record}
        trusted_root_path = evidence_root / trusted_root_record["path"]
        rc, rc_record, rc_path = read_json_input(
            public_root,
            args.rc_manifest,
            label="RC manifest",
            root_name="publicArtifacts",
        )
        subject_checksums_data, subject_checksums_record, subject_checksums_path = read_allowed_file(
            args.subject_checksums,
            evidence_root=evidence_root,
            public_root=public_root,
            label="attestation subject-checksum inventory",
        )

        validate_schema(go, "go-no-go.schema.json")
        validate_schema(matrix, "installation-matrix.schema.json")
        validate_schema(candidate_stage, "candidate-stage-evidence.schema.json")
        validate_schema(rc, "release-candidate-manifest.schema.json")
        validate_schema(attestation, "attestation-verification.schema.json")
        for label, value in (
            ("final Go/No-Go packet", go),
            ("final installation matrix", matrix),
            ("candidate-stage evidence", candidate_stage),
            ("RC manifest", rc),
            ("attestation verification report", attestation),
        ):
            reject_placeholders(value, label=label)

        require_identity(go["candidate"], identity, label="Go/No-Go candidate")
        require_identity(matrix["candidate"], identity, label="installation matrix candidate")
        require_identity(candidate_stage["candidate"], identity, label="candidate-stage candidate")
        if candidate_stage["candidate"]["tag"] != tag:
            raise GateError("candidate-stage tag differs from the exact promotion candidate")
        require_identity(
            {
                "version": rc["candidate"]["version"],
                "build": rc["candidate"]["build"],
                "commit": rc["source"]["commit"],
            },
            identity,
            label="RC manifest candidate",
        )
        if rc["source"]["tag"] != tag:
            raise GateError("RC manifest tag differs from the exact promotion candidate")
        expected_ref = f"refs/tags/{tag}"
        if attestation["source"] != {"commit": commit, "ref": expected_ref}:
            raise GateError("attestation source differs from the exact promotion tag and commit")

        canonical_dmg = exact_file(rc["artifacts"]["dmg"])
        expected_dmg_name = f"Vela-{version}-arm64.dmg"
        if canonical_dmg["filename"] != expected_dmg_name:
            raise GateError(f"promotion DMG must be named {expected_dmg_name}")
        matrix_dmg = matrix["candidate"]["artifact"]
        if matrix_dmg is None or matrix_dmg.get("kind") != "dmg":
            raise GateError("final installation matrix lacks the exact DMG binding")
        if exact_file(matrix_dmg) != canonical_dmg:
            raise GateError("installation matrix DMG differs from the RC manifest")
        stage_dmg = exact_file(candidate_stage["artifacts"]["dmg"])
        if stage_dmg != canonical_dmg:
            raise GateError("candidate-stage receipt DMG differs from the RC manifest")

        architecture = exact_file(rc["freeze"]["architecture"])
        if exact_file(candidate_stage["freeze"]["architecture"]) != architecture:
            raise GateError("candidate-stage architecture freeze differs from the RC manifest")
        if candidate_stage["signing"]["certificateSHA256"] != rc["signing"]["certificateSHA256"]:
            raise GateError("candidate-stage signing certificate differs from the RC manifest")

        run_validator(
            "validate_release_candidate.py",
            str(rc_path),
            "--stage",
            "structural",
            "--verify-files",
            "--artifacts-dir",
            str(public_root),
            "--candidate-version",
            version,
            "--build",
            str(build),
            "--tag",
            tag,
            "--commit",
            commit,
        )
        public_contract = public_root / rc["freeze"]["publicContract"]["filename"]
        run_validator(
            "validate_installation_matrix.py",
            str(matrix_path),
            "--candidate-version",
            version,
            "--build",
            str(build),
            "--commit",
            commit,
            "--evidence-root",
            str(evidence_root),
            "--artifacts-dir",
            str(public_root),
            "--public-contract",
            str(public_contract),
            "--verify-files",
        )
        run_validator(
            "validate_candidate_stage_evidence.py",
            str(stage_path),
            "--evidence-root",
            str(candidate_stage_root),
            "--candidate-version",
            version,
            "--build",
            str(build),
            "--tag",
            tag,
            "--commit",
            commit,
            "--architecture-sha256",
            architecture["sha256"],
            "--verify-files",
        )
        run_validator(
            "validate_go_no_go.py",
            str(go_path),
            "--expect",
            "go",
            "--evidence-root",
            str(evidence_root),
            "--candidate-version",
            version,
            "--build",
            str(build),
            "--commit",
            commit,
            "--artifact-sha256",
            canonical_dmg["sha256"],
            "--verify-files",
        )

        gates = {gate["id"]: gate for gate in go["gates"]}
        if set(gates) != GATE_IDS or len(go["gates"]) != len(GATE_IDS):
            raise GateError("final Go/No-Go packet lacks the exact ten-gate inventory")
        installation_reference = exact_reference(matrix_record)
        artifact_reference = exact_reference(attestation_record)
        if gates["installation"]["evidence"] != [installation_reference]:
            raise GateError("installation gate must reference only the exact final installation matrix")
        if gates["artifact"]["evidence"] != [artifact_reference]:
            raise GateError("artifact gate must reference only the exact attestation verification report")

        approval_roles = [approval["role"] for approval in go["approvals"]]
        if set(approval_roles) != APPROVAL_ROLES or len(approval_roles) != len(APPROVAL_ROLES):
            raise GateError("final Go/No-Go packet lacks the exact six accountable approvals")

        validation_time = datetime.now(timezone.utc)
        verified_at = parse_timestamp(
            attestation["verifiedAt"],
            label="attestation verifiedAt",
        )
        if verified_at > validation_time:
            raise GateError("attestation verifiedAt may not be in the future")
        approval_times: list[tuple[str, datetime]] = []
        for approval in go["approvals"]:
            approved_at = parse_timestamp(
                approval["approvedAt"],
                label=f"{approval['role']} approvedAt",
            )
            if approved_at < verified_at:
                raise GateError(
                    f"{approval['role']} approvedAt must be at or after attestation verifiedAt"
                )
            if approved_at > validation_time:
                raise GateError(f"{approval['role']} approvedAt may not be in the future")
            approval_times.append((approval["role"], approved_at))

        checksum_report = normalized_subject(
            attestation["subjectChecksums"],
            label="attestation subject-checksum inventory",
        )
        if checksum_report != exact_file(subject_checksums_record):
            raise GateError("attestation report differs from the supplied subject-checksum inventory")
        if normalized_subject(
            attestation["bundle"],
            label="offline GitHub attestation bundle",
        ) != exact_file(bundle_record):
            raise GateError("attestation report differs from the supplied offline bundle")
        if normalized_subject(
            attestation["trustedRoot"],
            label="offline GitHub trusted root",
        ) != exact_file(trusted_root_record):
            raise GateError("attestation report differs from the supplied offline trusted root")

        subjects: dict[str, dict[str, Any]] = {}
        for raw_subject in attestation["subjects"]:
            subject = normalized_subject(raw_subject, label="attestation subject")
            if subject["filename"] in subjects:
                raise GateError(f"duplicate attestation subject: {subject['filename']}")
            subjects[subject["filename"]] = subject
        inventory_rows = checksum_rows(
            subject_checksums_data,
            label="attestation subject-checksum inventory",
        )
        attested_rows = {
            filename: subject["sha256"] for filename, subject in subjects.items()
        }
        if inventory_rows != attested_rows:
            raise GateError(
                "attestation subject-checksum rows differ from the verified subject set"
            )

        public_records = list(rc["freeze"].values()) + list(rc["artifacts"].values())
        for record in public_records:
            require_public_record(
                public_root,
                record,
                label=f"public RC artifact {record['filename']}",
            )
            if subjects.get(record["filename"]) != exact_file(record):
                raise GateError(f"attestation subjects omit or change {record['filename']}")
        rc_subject = exact_file(rc_record)
        if subjects.get(rc_subject["filename"]) != rc_subject:
            raise GateError("attestation subjects omit or change the exact RC manifest")

        public_checksums = rc["artifacts"]["checksums"]
        public_checksum_data, _ = read_stage_file(
            public_root,
            public_checksums["filename"],
            label="public artifact checksum inventory",
            maximum_bytes=JSON_LIMIT,
        )
        public_rows = checksum_rows(
            public_checksum_data,
            label="public artifact checksum inventory",
        )
        for artifact_name in ("releaseManifest", "dmg", "sbom", "appcast"):
            artifact = rc["artifacts"][artifact_name]
            if public_rows.get(artifact["filename"]) != artifact["sha256"]:
                raise GateError(
                    f"public artifact checksum inventory does not verify {artifact['filename']}"
                )

        required_subjects = [
            canonical_dmg,
            rc_subject,
            exact_file(public_checksums),
        ]
        # The JSON report and bundle digest are only routing/binding metadata.
        # Trust is established here by replaying GitHub's verifier against the
        # frozen checksum inventory and every frozen subject, including the DMG
        # SPDX predicate, with no API token available to the verifier.
        run_offline_attestation_verifier(
            manifest=rc_path,
            public_root=public_root,
            subject_checksums=subject_checksums_path,
            bundle=bundle_path,
            bundle_sha256=bundle_record["sha256"],
            trusted_root=trusted_root_path,
            trusted_root_sha256=trusted_root_record["sha256"],
        )
        closed_at = datetime.now(timezone.utc)
        if verified_at > closed_at:
            raise GateError("attestation verifiedAt may not be after closure closedAt")
        for role, approved_at in approval_times:
            if approved_at > closed_at:
                raise GateError(f"{role} approvedAt may not be after closure closedAt")
        closure = {
            "schemaVersion": 1,
            "manifestKind": "promotionClosure",
            "visibility": "private",
            "stage": {
                "decision": "go",
                "promotionStatus": "closed",
                "verifyFilesRequired": True,
            },
            "candidate": {"version": version, "build": build, "tag": tag, "commit": commit},
            "artifact": {"kind": "dmg", **canonical_dmg},
            "inputs": {
                "goNoGo": go_record,
                "installationMatrix": matrix_record,
                "candidateStageEvidence": stage_record,
                "rcManifest": rc_record,
                "attestationVerification": attestation_record,
                "attestationBundle": bundle_record,
                "attestationTrustedRoot": trusted_root_record,
                "subjectChecksums": subject_checksums_record,
            },
            "bindings": {
                "gateIDs": sorted(GATE_IDS),
                "approvalRoles": sorted(APPROVAL_ROLES),
                "installationGateEvidence": installation_reference,
                "artifactGateEvidence": artifact_reference,
                "architectureSHA256": architecture["sha256"],
                "signingCertificateSHA256": rc["signing"]["certificateSHA256"],
                "attestation": {
                    "repository": attestation["repository"],
                    "signerWorkflow": attestation["signerWorkflow"],
                    "source": attestation["source"],
                    "result": attestation["result"],
                    "bundle": exact_file(bundle_record),
                    "trustedRoot": exact_file(trusted_root_record),
                    "requiredSubjects": required_subjects,
                },
            },
            "closedAt": closed_at.isoformat().replace("+00:00", "Z"),
        }
        validate_schema(closure, "promotion-closure.schema.json")
        reject_placeholders(closure, label="promotion closure")
        write_private_json(Path(args.output), evidence_root, closure)
        print(Path(args.output))
        return 0
    except (GateError, OSError, KeyError, TypeError, ValueError) as error:
        return main_error(error)


if __name__ == "__main__":
    raise SystemExit(main())
