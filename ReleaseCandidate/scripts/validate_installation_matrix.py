#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
from pathlib import Path, PurePosixPath

from _common import (
    GateError,
    checked_evidence,
    load_json,
    main_error,
    reject_forbidden_text,
    sha256,
    valid_commit,
    valid_sha256,
    validate_build_number,
    validate_schema,
)


CASE_PHASES = {
    # Clean install: Docs/09 clean-install inventory.
    "clean.standard.no-old-data": "cleanInstall",
    "clean.admin.no-old-data": "cleanInstall",
    "clean.old-data-only": "cleanInstall",
    "clean.helper-absent": "cleanInstall",
    "clean.helper-registered": "cleanInstall",
    "clean.cli-absent": "cleanInstall",
    "clean.cli-broken": "cleanInstall",
    "clean.factory-core": "cleanInstall",
    "clean.no-configuration": "cleanInstall",
    "clean.local-configuration": "cleanInstall",
    "clean.remote-configuration": "cleanInstall",
    "clean.applications-location": "cleanInstall",
    "clean.downloads-translocated": "cleanInstall",
    "clean.read-only-dmg": "cleanInstall",
    # Upgrade: every historical fixture plus the exact state matrix in Docs/09.
    "upgrade.fixture-v0.1": "upgrade",
    "upgrade.fixture-v0.2": "upgrade",
    "upgrade.fixture-v0.3": "upgrade",
    "upgrade.fixture-v0.4": "upgrade",
    "upgrade.fixture-v0.5": "upgrade",
    "upgrade.fixture-v0.6": "upgrade",
    "upgrade.fixture-v0.7": "upgrade",
    "upgrade.fixture-v0.8": "upgrade",
    "upgrade.stable-to-rc": "upgrade",
    "upgrade.beta-to-rc": "upgrade",
    "upgrade.rc1-to-rc2": "upgrade",
    "upgrade.rc-to-1.0": "upgrade",
    "upgrade.tun-off": "upgrade",
    "upgrade.tun-on": "upgrade",
    "upgrade.system-proxy-on": "upgrade",
    "upgrade.helper-old": "upgrade",
    "upgrade.helper-current": "upgrade",
    "upgrade.cli-old": "upgrade",
    "upgrade.cli-current": "upgrade",
    "upgrade.external-core-active": "upgrade",
    "upgrade.blocked-core": "upgrade",
    "upgrade.automatic-scenes": "upgrade",
    "upgrade.incomplete-journals": "upgrade",
    "upgrade.low-disk": "upgrade",
    "upgrade.sparkle-offline": "upgrade",
    # Repair.
    "repair.helper-reinstall": "repair",
    "repair.cli": "repair",
    "repair.support-bundle": "repair",
    "repair.safe-mode": "repair",
    "repair.profile-restore": "repair",
    "repair.update-journal": "repair",
    "repair.factory-core-fallback": "repair",
    "repair.data-export": "repair",
    # Uninstall.
    "uninstall.tun-stop-cleanup": "uninstall",
    "uninstall.helper-unregister": "uninstall",
    "uninstall.cli-symlink-removal": "uninstall",
    "uninstall.optional-user-data-removal": "uninstall",
    "uninstall.no-unknown-process-network-deletion": "uninstall",
    "uninstall.retained-data-policy": "uninstall",
    # Downgrade policy and recovery behavior.
    "downgrade.no-silent-downgrade": "downgrade",
    "downgrade.manual-previous-stable-schema-guard": "downgrade",
    "downgrade.backup-export-instructions": "downgrade",
    "downgrade.helper-core-compatibility-warning": "downgrade",
    "downgrade.no-write-compatibility-promise": "downgrade",
}

ABSENT_SURFACE_REQUIREMENTS = {
    "clean.cli-absent": {"productionCLI"},
    "clean.cli-broken": {"productionCLI"},
    "upgrade.cli-old": {"productionCLI"},
    "upgrade.cli-current": {"productionCLI"},
    "repair.cli": {"productionCLI"},
    "uninstall.cli-symlink-removal": {"productionCLI"},
    "upgrade.automatic-scenes": {"productionSceneStore", "productionAutomationSocket"},
}


def validate_relative_evidence_path(raw: str) -> None:
    if "\\" in raw or any(ord(character) < 32 or ord(character) == 127 for character in raw):
        raise GateError(f"matrix evidence path contains an unsafe character: {raw!r}")
    path = PurePosixPath(raw)
    if (
        path.is_absolute()
        or not path.parts
        or path.as_posix() != raw
        or any(part in {"", ".", ".."} for part in path.parts)
    ):
        raise GateError(f"matrix evidence path must be a normalized safe relative path: {raw}")


def validate_candidate(candidate: dict) -> bool:
    values = (candidate["version"], candidate["build"], candidate["commit"])
    if all(value is None for value in values):
        return False
    if (
        not isinstance(candidate["version"], str)
        or not isinstance(candidate["build"], int)
        or not valid_commit(candidate["commit"])
    ):
        raise GateError("installation matrix candidate identity must be entirely null or fully concrete")
    if re.fullmatch(r"1\.0\.0(?:-rc\.[1-9][0-9]*)?", candidate["version"]) is None:
        raise GateError("installation matrix candidate must be exactly 1.0.0 or 1.0.0-rc.N")
    validate_build_number(candidate["build"])
    return True


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate the exact Vela V1 install, upgrade, repair, uninstall, and downgrade matrix"
    )
    parser.add_argument("manifest")
    parser.add_argument("--allow-pending", action="store_true")
    parser.add_argument("--candidate-stage", action="store_true")
    parser.add_argument("--evidence-root")
    parser.add_argument("--artifacts-dir")
    parser.add_argument(
        "--public-contract",
        default="Contracts/v1/public-contract-freeze.json",
    )
    parser.add_argument("--verify-files", action="store_true")
    parser.add_argument("--candidate-version")
    parser.add_argument("--build", type=int)
    parser.add_argument("--commit")
    args = parser.parse_args()

    try:
        if args.allow_pending and args.candidate_stage:
            raise GateError("--allow-pending and --candidate-stage are mutually exclusive")
        value = load_json(Path(args.manifest), label="installation matrix")
        validate_schema(value, "installation-matrix.schema.json")
        reject_forbidden_text(value, label="installation matrix")

        cases = value["cases"]
        ids = [case["id"] for case in cases]
        if set(ids) != set(CASE_PHASES) or len(ids) != len(CASE_PHASES):
            missing = sorted(set(CASE_PHASES) - set(ids))
            unknown = sorted(set(ids) - set(CASE_PHASES))
            duplicates = sorted({case_id for case_id in ids if ids.count(case_id) > 1})
            raise GateError(
                "installation matrix case inventory is not exact"
                f"; missing={missing or 'none'}; unknown={unknown or 'none'}; "
                f"duplicates={duplicates or 'none'}"
            )
        for case in cases:
            if case["phase"] != CASE_PHASES[case["id"]]:
                raise GateError(f"installation matrix case has the wrong phase: {case['id']}")

        candidate = value["candidate"]
        concrete_candidate = validate_candidate(candidate)
        expected = {
            "version": args.candidate_version,
            "build": args.build,
            "commit": args.commit,
        }
        for key, expected_value in expected.items():
            if expected_value is not None and candidate[key] != expected_value:
                raise GateError(f"installation matrix candidate {key} differs from release preflight")

        contract = load_json(Path(args.public_contract), label="public contract freeze")
        absent_raw = contract.get("absentSurfaces")
        if not isinstance(absent_raw, list) or not all(isinstance(item, str) for item in absent_raw):
            raise GateError("public contract freeze lacks an exact absentSurfaces inventory")
        absent_surfaces = set(absent_raw)

        evidence_root: Path | None = None
        if args.verify_files:
            if not args.evidence_root:
                raise GateError("--verify-files requires --evidence-root")
            evidence_root = Path(args.evidence_root)
            if not evidence_root.is_dir() or evidence_root.is_symlink():
                raise GateError("installation matrix evidence root is missing or unsafe")
            for path in evidence_root.rglob("*"):
                if path.is_symlink():
                    raise GateError(f"installation matrix evidence root contains a symlink: {path}")

        incomplete: list[str] = []
        any_passed = False
        for case in cases:
            case_id = case["id"]
            status = case["status"]
            evidence = case["evidence"]
            required_absences = ABSENT_SURFACE_REQUIREMENTS.get(case_id, set())
            still_absent = required_absences & absent_surfaces
            if still_absent and status != "blockedAbsentSurface":
                raise GateError(
                    f"{case_id} must remain blockedAbsentSurface while {sorted(still_absent)} are absent"
                )
            if not still_absent and status == "blockedAbsentSurface":
                raise GateError(f"{case_id} claims an absent surface that is present in the public contract")
            if not required_absences and status == "blockedAbsentSurface":
                raise GateError(f"{case_id} is not an approved absent-surface case")

            if status == "passed":
                any_passed = True
                if not evidence:
                    raise GateError(f"passed installation matrix case lacks evidence: {case_id}")
            elif evidence:
                raise GateError(f"non-passed installation matrix case carries unverified evidence: {case_id}")

            for reference in evidence:
                validate_relative_evidence_path(reference["path"])
                if not valid_sha256(reference["sha256"]):
                    raise GateError(f"installation matrix evidence SHA-256 is invalid: {case_id}")
                if evidence_root is not None:
                    checked_evidence(evidence_root, reference["path"], reference["sha256"])

            if status != "passed":
                incomplete.append(f"{case_id}: {status}")

        if any_passed and not concrete_candidate:
            raise GateError("passed installation matrix evidence must bind a concrete candidate")

        artifact = candidate["artifact"]
        if artifact is not None:
            if not concrete_candidate:
                raise GateError("installation matrix artifact must bind a concrete candidate")
            expected_filename = f"Vela-{candidate['version']}-arm64.dmg"
            if artifact["filename"] != expected_filename or Path(artifact["filename"]).name != artifact["filename"]:
                raise GateError(f"installation matrix artifact must be named {expected_filename}")
            if not valid_sha256(artifact["sha256"]):
                raise GateError("installation matrix artifact SHA-256 is invalid")
            if args.verify_files:
                if not args.artifacts_dir:
                    raise GateError("artifact verification requires --artifacts-dir")
                artifacts = Path(args.artifacts_dir)
                if not artifacts.is_dir() or artifacts.is_symlink():
                    raise GateError("installation matrix artifacts directory is missing or unsafe")
                for path in artifacts.rglob("*"):
                    if path.is_symlink():
                        raise GateError(f"installation matrix artifacts directory contains a symlink: {path}")
                artifact_path = artifacts / artifact["filename"]
                if not artifact_path.is_file() or artifact_path.is_symlink():
                    raise GateError("installation matrix candidate artifact is missing or unsafe")
                if (
                    artifact_path.stat().st_size != artifact["size"]
                    or sha256(artifact_path) != artifact["sha256"]
                ):
                    raise GateError("installation matrix candidate artifact bytes differ from the manifest")

        if args.candidate_stage:
            if not concrete_candidate:
                raise GateError("candidate-stage installation matrix must bind a concrete candidate")
            if artifact is not None:
                raise GateError("candidate-stage installation matrix must keep artifact=null before build")
            invalid_stage_statuses = {
                case["id"]: case["status"]
                for case in cases
                if case["status"] not in {"pending", "blockedAbsentSurface"}
            }
            if invalid_stage_statuses:
                raise GateError(
                    f"candidate-stage matrix may contain only pending/blocked cases: {invalid_stage_statuses}"
                )
            if value["decision"] != "noGo" or not value["blockers"]:
                raise GateError("candidate-stage installation matrix must remain explicit No-Go")
            print(
                f"Candidate-stage installation matrix passed structurally for {candidate['version']} "
                f"({candidate['build']}); final signed DMG execution remains required."
            )
            return 0

        pending_artifact = artifact is None
        if incomplete or pending_artifact:
            if not args.allow_pending:
                if pending_artifact and not incomplete:
                    raise GateError("final installation matrix lacks the exact signed DMG artifact binding")
                raise GateError(
                    "installation matrix is not closed:\n- " + "\n- ".join(incomplete)
                )
            if value["decision"] != "noGo" or not value["blockers"]:
                raise GateError("incomplete installation matrix must remain an explicit No-Go with blockers")
            print(
                "Installation matrix structure is valid and truthfully No-Go "
                f"({len(incomplete)} incomplete cases; artifact={'pending' if pending_artifact else 'bound'})."
            )
            return 0

        if not concrete_candidate:
            raise GateError("closed installation matrix must bind a concrete candidate")
        if not args.verify_files:
            raise GateError("closed installation matrix requires --verify-files against protected evidence and DMG bytes")
        if value["decision"] != "go" or value["blockers"]:
            raise GateError("fully passed installation matrix requires decision=go and no blockers")
        print(f"Installation matrix passed for {candidate['version']} ({candidate['build']}).")
        return 0
    except (GateError, OSError, KeyError, TypeError, ValueError) as error:
        return main_error(error)


if __name__ == "__main__":
    raise SystemExit(main())
