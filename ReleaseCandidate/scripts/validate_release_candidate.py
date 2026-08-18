#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
from pathlib import Path

from _common import (
    GateError,
    load_json,
    main_error,
    parse_semver,
    reject_forbidden_text,
    sha256,
    valid_commit,
    valid_sha256,
    validate_build_number,
    validate_schema,
)


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate a Vela RC manifest and its immutable files")
    parser.add_argument("manifest")
    parser.add_argument("--artifacts-dir")
    parser.add_argument("--verify-files", action="store_true")
    parser.add_argument("--allow-incomplete", action="store_true")
    parser.add_argument("--stage", choices=["structural", "local", "final"], default="final")
    parser.add_argument("--version")
    parser.add_argument("--candidate-version")
    parser.add_argument("--build", type=int)
    parser.add_argument("--tag")
    parser.add_argument("--commit")
    args = parser.parse_args()
    try:
        value = load_json(Path(args.manifest), label="RC manifest")
        validate_schema(value, "release-candidate-manifest.schema.json")
        reject_forbidden_text(value, label="RC manifest")
        candidate = value["candidate"]
        source = value["source"]
        base, prerelease = parse_semver(candidate["version"])
        if base != candidate["marketingVersion"]:
            raise GateError("candidate SemVer base differs from marketingVersion")
        validate_build_number(candidate["build"])
        if candidate["channel"] == "rc":
            if prerelease is None or re.fullmatch(r"rc\.[1-9][0-9]*", prerelease) is None:
                raise GateError("RC candidate must use rc.N prerelease")
            if candidate["appUpdateChannel"] != "beta":
                raise GateError("RC must use the frozen beta App update channel")
            sequence = prerelease.split(".", 1)[1]
            if candidate["prereleaseLabel"] != f"RC {sequence}":
                raise GateError("RC prerelease display label does not match its sequence")
        elif (
            prerelease is not None
            or candidate["appUpdateChannel"] != "stable"
            or candidate["prereleaseLabel"] is not None
        ):
            raise GateError("Stable candidate/channel mapping is invalid")
        if source["tag"] != f"v{candidate['version']}" or not valid_commit(source["commit"]):
            raise GateError("RC source tag/commit is invalid")

        expected = {
            "marketingVersion": args.version,
            "version": args.candidate_version,
            "build": args.build,
        }
        for key, wanted in expected.items():
            if wanted is not None and candidate[key] != wanted:
                raise GateError(f"candidate {key} differs from expected value")
        if args.tag and source["tag"] != args.tag:
            raise GateError("candidate tag differs from expected value")
        if args.commit and source["commit"] != args.commit:
            raise GateError("candidate commit differs from expected value")

        expected_dmg = f"Vela-{candidate['version']}-arm64.dmg"
        if value["artifacts"]["dmg"]["filename"] != expected_dmg:
            raise GateError(f"RC DMG must be named {expected_dmg}")
        all_records = list(value["freeze"].values()) + list(value["artifacts"].values())
        names: set[str] = set()
        for record in all_records:
            name = record["filename"]
            if Path(name).name != name or name in names:
                raise GateError(f"unsafe or duplicate RC file basename: {name}")
            if not valid_sha256(record["sha256"]):
                raise GateError(f"invalid RC file SHA-256: {name}")
            names.add(name)

        if args.verify_files:
            if args.artifacts_dir is None:
                raise GateError("--verify-files requires --artifacts-dir")
            root = Path(args.artifacts_dir)
            if not root.is_dir() or root.is_symlink():
                raise GateError("artifacts directory is missing or unsafe")
            for record in all_records:
                path = root / record["filename"]
                if not path.is_file() or path.is_symlink():
                    raise GateError(f"RC file is missing or unsafe: {record['filename']}")
                if path.stat().st_size != record["size"] or sha256(path) != record["sha256"]:
                    raise GateError(f"RC file differs from manifest: {record['filename']}")

        if not valid_sha256(value["signing"]["certificateSHA256"]):
            raise GateError("signing certificate fingerprint is invalid")
        non_pass = {name: status for name, status in value["quality"].items() if status != "pass"}
        attestation = value["provenance"]["attestation"]
        expected_subjects = {
            value["artifacts"][name]["filename"]: value["artifacts"][name]["sha256"]
            for name in ("dmg", "sbom")
        }
        actual_subjects: dict[str, str] = {}
        for subject in attestation["subjects"]:
            if Path(subject["filename"]).name != subject["filename"] or not valid_sha256(subject["sha256"]):
                raise GateError("attestation subject is invalid")
            if subject["filename"] in actual_subjects:
                raise GateError("attestation subject is duplicated")
            actual_subjects[subject["filename"]] = subject["sha256"]
        if actual_subjects != expected_subjects:
            raise GateError("pendingExternal attestation subjects must exactly match the RC DMG and SBOM")
        workflow = value["provenance"]["workflow"]
        if workflow["repository"] is None:
            if workflow["runID"] is not None or workflow["runnerClass"] != "local/macos/arm64":
                raise GateError("local provenance must not claim a GitHub run")
        elif (
            workflow["repository"] != "Spacebody/Vela"
            or not workflow["runID"]
            or workflow["runnerClass"] != "github-actions/macos/arm64"
        ):
            raise GateError("GitHub provenance does not bind the protected Spacebody/Vela runner")
        stage = "structural" if args.allow_incomplete else args.stage
        if stage == "local" and attestation["status"] == "pendingExternal":
            non_artifact = {
                name: status
                for name, status in value["quality"].items()
                if name != "artifact" and status != "pass"
            }
            if non_artifact or value["quality"]["artifact"] != "pending":
                raise GateError(
                    "local pre-attestation stage requires all non-artifact gates pass and artifact=pending"
                )
        elif stage == "local":
            if non_pass:
                raise GateError(f"RC quality gates are incomplete: {non_pass}")
        elif stage == "final":
            raise GateError(
                "embedded attestation is intentionally pendingExternal; final verification must run verify_rc_attestations.sh and remain outside the immutable RC manifest"
            )
        print(
            f"RC manifest validation passed: {candidate['version']} ({candidate['build']})"
            + (f" [{stage} stage]" if stage != "final" else "")
        )
        return 0
    except (GateError, OSError, KeyError, TypeError, ValueError) as error:
        return main_error(error)


if __name__ == "__main__":
    raise SystemExit(main())
