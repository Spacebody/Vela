#!/usr/bin/env python3
"""Validate private candidate-stage evidence and promotion byte identity."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path, PurePosixPath

from _common import GateError, load_json, main_error, valid_sha256, validate_schema
from candidate_stage_common import (
    JSON_LIMIT,
    SPARKLE_VERIFICATION_TOOL_VERSION,
    UUID_RE,
    all_file_records,
    candidate_contract,
    collect_updates_subjects,
    decode_json,
    notary_summary,
    read_stage_file,
    reject_placeholders,
    reject_text_artifact,
    require_updates_subject,
    require_private_manifest,
    secure_directory,
    stage_directory,
    validate_app_receipt,
    validate_archive_receipt,
    validate_candidate_appcast,
    validate_record,
    validate_sbom,
    validate_updates_checksums,
    verify_archive_uuid_binding,
)


def verify_sealed_archive_replay(
    repository: Path,
    *,
    archive_container: Path,
    live_archive: Path,
    receipt: Path,
) -> None:
    verifier = repository / "Release/scripts/verify_archive_container.py"
    if not verifier.is_file() or verifier.is_symlink():
        raise GateError("release source lacks the tracked xcarchive replay verifier")
    command = [
        sys.executable,
        str(verifier),
        "--archive-zip",
        str(archive_container),
        "--live-archive",
        str(live_archive),
        "--receipt",
        str(receipt),
        "--require",
        "Vela",
        "--require",
        "VelaHelper",
    ]
    try:
        result = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=300,
            check=False,
        )
    except subprocess.SubprocessError as error:
        raise GateError("sealed xcarchive replay verification failed") from error
    if result.returncode != 0:
        detail = result.stdout.strip()
        suffix = f": {detail}" if detail else ""
        raise GateError(f"sealed xcarchive replay verification failed{suffix}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate immutable private evidence before candidate promotion"
    )
    parser.add_argument("manifest")
    parser.add_argument("--evidence-root")
    parser.add_argument("--verify-files", action="store_true")
    parser.add_argument("--candidate-version")
    parser.add_argument("--build", type=int)
    parser.add_argument("--tag")
    parser.add_argument("--commit")
    parser.add_argument("--architecture-sha256")
    args = parser.parse_args()

    try:
        evidence_root = (
            secure_directory(args.evidence_root, label="candidate evidence root")
            if args.evidence_root
            else None
        )
        if args.verify_files and evidence_root is None:
            raise GateError("--verify-files requires --evidence-root")
        manifest_path = Path(args.manifest)
        require_private_manifest(manifest_path, evidence_root)
        value = load_json(manifest_path, label="candidate-stage evidence")
        validate_schema(value, "candidate-stage-evidence.schema.json")
        reject_placeholders(value, label="candidate-stage evidence")

        candidate = value["candidate"]
        candidate_contract(
            version=candidate["version"],
            build=candidate["build"],
            tag=candidate["tag"],
            commit=candidate["commit"],
        )
        expected = {
            "version": args.candidate_version,
            "build": args.build,
            "tag": args.tag,
            "commit": args.commit,
        }
        for key, wanted in expected.items():
            if wanted is not None and candidate[key] != wanted:
                raise GateError(f"candidate {key} differs from the expected promotion identity")

        architecture = value["freeze"]["architecture"]
        dmg = value["artifacts"]["dmg"]
        app_archive = value["artifacts"]["appArchive"]
        archive_container = value["artifacts"]["archiveContainer"]
        appcast = value["artifacts"]["appcast"]
        sbom = value["artifacts"]["sbom"]
        release_notes = value["artifacts"]["signedReleaseNotes"]
        updates_root = value["artifacts"]["updatesRoot"]
        updates_checksums = value["artifacts"]["updatesChecksums"]
        updates_subjects = value["artifacts"]["updatesSubjects"]
        app_receipt = value["receipts"]["app"]
        archive_receipt = value["receipts"]["archive"]
        archive_directory_relative = value["receipts"]["archiveDirectory"]
        app_notary = value["receipts"]["notarization"]["app"]
        dmg_notary = value["receipts"]["notarization"]["dmg"]
        certificate_sha256 = value["signing"]["certificateSHA256"]
        sparkle_verification = value["signing"]["sparkleVerification"]

        records = all_file_records(value)
        paths: dict[str, dict] = {}
        for label, record in records:
            validate_record(record, label=label)
            existing = paths.get(record["path"])
            if existing is not None and existing != record:
                raise GateError(
                    f"conflicting candidate-stage evidence path: {record['path']}"
                )
            paths[record["path"]] = record
        root_path = PurePosixPath(updates_root)
        if (
            root_path.is_absolute()
            or ".." in root_path.parts
            or "." in root_path.parts
            or root_path.as_posix() != updates_root
        ):
            raise GateError("updates root path is unsafe")
        archive_path = PurePosixPath(archive_directory_relative)
        if (
            archive_path.is_absolute()
            or ".." in archive_path.parts
            or "." in archive_path.parts
            or archive_path.as_posix() != archive_directory_relative
            or archive_path.name != "Vela.xcarchive"
        ):
            raise GateError("archive directory path is unsafe")
        if architecture["filename"] != "architecture-freeze.json":
            raise GateError("architecture freeze must be named architecture-freeze.json")
        expected_dmg = f"Vela-{candidate['version']}-arm64.dmg"
        if dmg["filename"] != expected_dmg:
            raise GateError(f"candidate DMG must be named {expected_dmg}")
        expected_app_archive = (
            f"Vela-{candidate['version']}-{candidate['build']}-app-notary.zip"
        )
        if app_archive["filename"] != expected_app_archive:
            raise GateError(f"sealed App archive must be named {expected_app_archive}")
        archive_name = archive_container["filename"].casefold()
        if not archive_name.endswith(".zip") or "xcarchive" not in archive_name[:-4]:
            raise GateError("sealed archive container filename is invalid")
        if appcast["filename"] != "appcast.xml":
            raise GateError("signed appcast must be named appcast.xml")
        if not sbom["filename"].endswith(".spdx.json"):
            raise GateError("SBOM filename is invalid")
        if not updates_checksums["filename"].endswith(".txt"):
            raise GateError("updates checksum inventory filename is invalid")
        require_updates_subject(dmg, updates_subjects, label="DMG")
        require_updates_subject(appcast, updates_subjects, label="appcast")
        require_updates_subject(
            release_notes,
            updates_subjects,
            label="signed release notes",
        )
        if app_notary["file"]["filename"] != "notary-app-result.json":
            raise GateError("App notary receipt filename is invalid")
        if dmg_notary["file"]["filename"] != "notary-dmg-result.json":
            raise GateError("DMG notary receipt filename is invalid")
        for label, receipt in (("App", app_notary), ("DMG", dmg_notary)):
            if receipt["status"] != "Accepted" or UUID_RE.fullmatch(receipt["submissionID"]) is None:
                raise GateError(f"{label} notary summary is invalid")
        if not valid_sha256(certificate_sha256):
            raise GateError("signing certificate SHA-256 is invalid")
        if sparkle_verification != {
            "status": "verified",
            "toolVersion": SPARKLE_VERIFICATION_TOOL_VERSION,
            "appcastSHA256": appcast["sha256"],
        }:
            raise GateError("Sparkle verification receipt does not bind the exact appcast bytes")
        if args.architecture_sha256 is not None and architecture["sha256"] != args.architecture_sha256:
            raise GateError("architecture SHA-256 differs from the expected promotion freeze")

        if args.verify_files:
            assert evidence_root is not None
            actual_updates_directory, actual_updates_root = stage_directory(
                evidence_root,
                updates_root,
                label="updates root",
            )
            if actual_updates_root != updates_root:
                raise GateError("retained updates root differs from candidate-stage evidence")
            _, collected_subjects = collect_updates_subjects(
                evidence_root,
                actual_updates_directory,
                excluded_file=evidence_root / updates_checksums["path"],
            )
            if collected_subjects != updates_subjects:
                raise GateError("retained updates directory differs from the complete inventory")
            verified: dict[str, tuple[bytes, dict]] = {}
            for label, record in records:
                hash_only = label in {"DMG", "App archive", "archive container"} or label.startswith(
                    "updates subject "
                )
                maximum = (
                    None
                    if hash_only
                    else JSON_LIMIT
                )
                data, actual = read_stage_file(
                    evidence_root,
                    record["path"],
                    label=label,
                    maximum_bytes=maximum,
                    retain_bytes=not hash_only,
                )
                if actual != record:
                    raise GateError(f"{label} bytes differ from candidate-stage evidence")
                verified[label] = (data, actual)

            decode_json(verified["architecture freeze"][0], label="architecture freeze")
            reject_text_artifact(verified["appcast"][0], label="signed appcast")
            validate_candidate_appcast(
                verified["appcast"][0],
                build=candidate["build"],
                dmg_filename=dmg["filename"],
                release_notes_filename=release_notes["filename"],
            )
            validate_sbom(decode_json(verified["SBOM"][0], label="SBOM"))
            reject_text_artifact(
                verified["signed release notes"][0],
                label="signed release notes",
            )
            validate_updates_checksums(
                verified["updates checksum inventory"][0],
                updates_root=updates_root,
                subjects=updates_subjects,
                checksums_record=updates_checksums,
            )
            actual_app_notary = notary_summary(
                decode_json(verified["App notary receipt"][0], label="App notary receipt"),
                app_notary["file"],
                label="App",
            )
            actual_dmg_notary = notary_summary(
                decode_json(verified["DMG notary receipt"][0], label="DMG notary receipt"),
                dmg_notary["file"],
                label="DMG",
            )
            if actual_app_notary != app_notary or actual_dmg_notary != dmg_notary:
                raise GateError("retained notary receipt summary differs from candidate-stage evidence")
            archive_value = decode_json(
                verified["archive receipt"][0],
                label="archive verification receipt",
            )
            validate_archive_receipt(archive_value)
            archive_directory, actual_archive_relative = stage_directory(
                evidence_root,
                archive_directory_relative,
                label="xcarchive directory",
            )
            if actual_archive_relative != archive_directory_relative:
                raise GateError("retained archive directory differs from candidate-stage evidence")
            verify_archive_uuid_binding(
                Path(__file__).resolve().parents[2],
                archive=archive_directory,
                receipt=evidence_root / archive_receipt["path"],
            )
            verify_sealed_archive_replay(
                Path(__file__).resolve().parents[2],
                archive_container=evidence_root / archive_container["path"],
                live_archive=archive_directory,
                receipt=evidence_root / archive_receipt["path"],
            )
            app_value = decode_json(
                verified["App receipt"][0],
                label="App verification receipt",
            )
            validate_app_receipt(
                app_value,
                version=candidate["version"],
                build=candidate["build"],
                tag=candidate["tag"],
                commit=candidate["commit"],
                architecture_sha256=architecture["sha256"],
                dmg_record=dmg,
                app_archive_record=app_archive,
                appcast_record=appcast,
                certificate_sha256=certificate_sha256,
                app_notary=app_notary,
                dmg_notary=dmg_notary,
            )

        print(
            "Candidate-stage evidence validation passed: "
            f"{candidate['version']} ({candidate['build']}); decision remains No-Go, promotion pending"
        )
        return 0
    except (GateError, OSError, KeyError, TypeError, ValueError) as error:
        return main_error(error)


if __name__ == "__main__":
    raise SystemExit(main())
