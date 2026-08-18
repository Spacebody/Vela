#!/usr/bin/env python3
"""Generate immutable private evidence for Vela's pre-promotion candidate stage."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

from _common import GateError, main_error, valid_sha256, validate_schema
from candidate_stage_common import (
    CHECKSUM_LIMIT,
    JSON_LIMIT,
    candidate_contract,
    collect_updates_subjects,
    decode_json,
    notary_summary,
    read_stage_file,
    reject_placeholders,
    reject_text_artifact,
    require_updates_subject,
    secure_directory,
    stage_directory,
    validate_app_receipt,
    validate_archive_receipt,
    validate_candidate_appcast,
    validate_sbom,
    validate_updates_checksums,
    verify_archive_uuid_binding,
    verify_signed_appcast,
    verify_repository,
    write_private_json,
)


def verify_sealed_archive_replay(
    repository: Path,
    *,
    archive_container: Path,
    live_archive: Path,
    receipt: Path,
    public_contract: Path | None = None,
) -> None:
    verifier = repository / "Release/scripts/verify_archive_container.py"
    if not verifier.is_file() or verifier.is_symlink():
        raise GateError("candidate source lacks the tracked xcarchive replay verifier")
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
    if public_contract is not None:
        command.extend(("--public-contract", str(public_contract)))
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
        description="Generate private No-Go/pending evidence for a built Vela candidate"
    )
    parser.add_argument("--repository-root", default=".")
    parser.add_argument("--evidence-root", required=True)
    parser.add_argument("--candidate-version", required=True)
    parser.add_argument("--build", required=True, type=int)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--architecture-freeze", required=True)
    parser.add_argument("--dmg", required=True)
    parser.add_argument("--app-archive", required=True)
    parser.add_argument("--archive-container", required=True)
    parser.add_argument("--appcast", required=True)
    parser.add_argument("--sbom", required=True)
    parser.add_argument("--signed-release-notes", required=True)
    parser.add_argument("--updates-root", required=True)
    parser.add_argument("--updates-checksums", required=True)
    parser.add_argument("--app-receipt", required=True)
    parser.add_argument("--archive-receipt", required=True)
    parser.add_argument("--archive-directory", required=True)
    parser.add_argument("--app-notary-receipt", required=True)
    parser.add_argument("--dmg-notary-receipt", required=True)
    parser.add_argument("--sparkle-sign-update", required=True)
    parser.add_argument("--sparkle-ed-key-file", required=True)
    parser.add_argument("--signing-certificate-sha256", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    try:
        repository = secure_directory(args.repository_root, label="repository root")
        evidence_root = secure_directory(args.evidence_root, label="candidate evidence root")
        candidate_contract(
            version=args.candidate_version,
            build=args.build,
            tag=args.tag,
            commit=args.commit,
        )
        verify_repository(repository, tag=args.tag, commit=args.commit)
        certificate_sha256 = args.signing_certificate_sha256
        if not valid_sha256(certificate_sha256):
            raise GateError("signing certificate SHA-256 must be a non-zero lowercase digest")

        architecture_data, architecture_record = read_stage_file(
            evidence_root,
            args.architecture_freeze,
            label="architecture freeze",
            maximum_bytes=JSON_LIMIT,
        )
        if architecture_record["filename"] != "architecture-freeze.json":
            raise GateError("architecture freeze must be named architecture-freeze.json")
        decode_json(architecture_data, label="architecture freeze")

        _, dmg_record = read_stage_file(
            evidence_root,
            args.dmg,
            label="candidate DMG",
            retain_bytes=False,
        )
        expected_dmg = f"Vela-{args.candidate_version}-arm64.dmg"
        if dmg_record["filename"] != expected_dmg:
            raise GateError(f"candidate DMG must be named {expected_dmg}")

        _, app_archive_record = read_stage_file(
            evidence_root,
            args.app_archive,
            label="sealed App archive",
            retain_bytes=False,
        )
        expected_app_archive = (
            f"Vela-{args.candidate_version}-{args.build}-app-notary.zip"
        )
        if app_archive_record["filename"] != expected_app_archive:
            raise GateError(f"sealed App archive must be named {expected_app_archive}")

        _, archive_container_record = read_stage_file(
            evidence_root,
            args.archive_container,
            label="sealed xcarchive container",
            retain_bytes=False,
        )
        archive_name = archive_container_record["filename"].casefold()
        if not archive_name.endswith(".zip") or "xcarchive" not in archive_name[:-4]:
            raise GateError("sealed archive container must use an xcarchive ZIP filename")

        appcast_data, appcast_record = read_stage_file(
            evidence_root,
            args.appcast,
            label="signed appcast",
            maximum_bytes=JSON_LIMIT,
        )
        if appcast_record["filename"] != "appcast.xml":
            raise GateError("signed appcast must be named appcast.xml")
        reject_text_artifact(appcast_data, label="signed appcast")

        sbom_data, sbom_record = read_stage_file(
            evidence_root,
            args.sbom,
            label="SBOM",
            maximum_bytes=JSON_LIMIT,
        )
        if not sbom_record["filename"].endswith(".spdx.json"):
            raise GateError("SBOM must use an .spdx.json filename")
        validate_sbom(decode_json(sbom_data, label="SBOM"))

        release_notes_data, release_notes_record = read_stage_file(
            evidence_root,
            args.signed_release_notes,
            label="signed release notes",
            maximum_bytes=JSON_LIMIT,
        )
        reject_text_artifact(release_notes_data, label="signed release notes")
        validate_candidate_appcast(
            appcast_data,
            build=args.build,
            dmg_filename=dmg_record["filename"],
            release_notes_filename=release_notes_record["filename"],
        )

        checksums_data, checksums_record = read_stage_file(
            evidence_root,
            args.updates_checksums,
            label="updates checksum inventory",
            maximum_bytes=CHECKSUM_LIMIT,
        )
        if not checksums_record["filename"].endswith(".txt"):
            raise GateError("updates checksum inventory must use a .txt filename")
        updates_directory, updates_root = stage_directory(
            evidence_root,
            args.updates_root,
            label="updates root",
        )
        collected_root, updates_subjects = collect_updates_subjects(
            evidence_root,
            args.updates_root,
            excluded_file=evidence_root / checksums_record["path"],
        )
        if collected_root != updates_root:
            raise GateError("updates root changed while candidate evidence was generated")
        validate_updates_checksums(
            checksums_data,
            updates_root=updates_root,
            subjects=updates_subjects,
            checksums_record=checksums_record,
        )
        require_updates_subject(dmg_record, updates_subjects, label="DMG")
        require_updates_subject(appcast_record, updates_subjects, label="appcast")
        require_updates_subject(
            release_notes_record,
            updates_subjects,
            label="signed release notes",
        )

        app_notary_data, app_notary_record = read_stage_file(
            evidence_root,
            args.app_notary_receipt,
            label="App notary receipt",
            maximum_bytes=JSON_LIMIT,
        )
        dmg_notary_data, dmg_notary_record = read_stage_file(
            evidence_root,
            args.dmg_notary_receipt,
            label="DMG notary receipt",
            maximum_bytes=JSON_LIMIT,
        )
        if app_notary_record["filename"] != "notary-app-result.json":
            raise GateError("App notary receipt must be named notary-app-result.json")
        if dmg_notary_record["filename"] != "notary-dmg-result.json":
            raise GateError("DMG notary receipt must be named notary-dmg-result.json")
        app_notary = notary_summary(
            decode_json(app_notary_data, label="App notary receipt"),
            app_notary_record,
            label="App",
        )
        dmg_notary = notary_summary(
            decode_json(dmg_notary_data, label="DMG notary receipt"),
            dmg_notary_record,
            label="DMG",
        )

        app_receipt_data, app_receipt_record = read_stage_file(
            evidence_root,
            args.app_receipt,
            label="App verification receipt",
            maximum_bytes=JSON_LIMIT,
        )
        archive_receipt_data, archive_receipt_record = read_stage_file(
            evidence_root,
            args.archive_receipt,
            label="archive verification receipt",
            maximum_bytes=JSON_LIMIT,
        )
        if app_receipt_record["filename"].endswith(".json") is False:
            raise GateError("App verification receipt must be JSON")
        if archive_receipt_record["filename"].endswith(".json") is False:
            raise GateError("archive verification receipt must be JSON")
        app_receipt = decode_json(app_receipt_data, label="App verification receipt")
        archive_receipt = decode_json(
            archive_receipt_data,
            label="archive verification receipt",
        )
        validate_archive_receipt(archive_receipt)
        archive_directory, archive_directory_relative = stage_directory(
            evidence_root,
            args.archive_directory,
            label="xcarchive directory",
        )
        if archive_directory.name != "Vela.xcarchive":
            raise GateError("archive directory must be named Vela.xcarchive")
        validate_app_receipt(
            app_receipt,
            version=args.candidate_version,
            build=args.build,
            tag=args.tag,
            commit=args.commit,
            architecture_sha256=architecture_record["sha256"],
            dmg_record=dmg_record,
            app_archive_record=app_archive_record,
            appcast_record=appcast_record,
            certificate_sha256=certificate_sha256,
            app_notary=app_notary,
            dmg_notary=dmg_notary,
        )

        sparkle_verification = verify_signed_appcast(
            repository,
            appcast=evidence_root / appcast_record["path"],
            updates_root=updates_directory,
            sign_update=args.sparkle_sign_update,
            ed_key_file=args.sparkle_ed_key_file,
            appcast_sha256=appcast_record["sha256"],
        )
        verify_archive_uuid_binding(
            repository,
            archive=archive_directory,
            receipt=evidence_root / archive_receipt_record["path"],
            public_contract=repository / "Contracts/v1/public-contract-freeze.json",
        )
        verify_sealed_archive_replay(
            repository,
            archive_container=evidence_root / archive_container_record["path"],
            live_archive=archive_directory,
            receipt=evidence_root / archive_receipt_record["path"],
            public_contract=repository / "Contracts/v1/public-contract-freeze.json",
        )
        verify_repository(repository, tag=args.tag, commit=args.commit)
        final_appcast_data, final_appcast_record = read_stage_file(
            evidence_root,
            appcast_record["path"],
            label="signed appcast after verification",
            maximum_bytes=JSON_LIMIT,
        )
        final_checksums_data, final_checksums_record = read_stage_file(
            evidence_root,
            checksums_record["path"],
            label="updates checksum inventory after verification",
            maximum_bytes=CHECKSUM_LIMIT,
        )
        _, final_app_archive_record = read_stage_file(
            evidence_root,
            app_archive_record["path"],
            label="sealed App archive after verification",
            retain_bytes=False,
        )
        _, final_archive_container_record = read_stage_file(
            evidence_root,
            archive_container_record["path"],
            label="sealed xcarchive container after verification",
            retain_bytes=False,
        )
        _, final_updates_subjects = collect_updates_subjects(
            evidence_root,
            updates_directory,
            excluded_file=evidence_root / checksums_record["path"],
        )
        if (
            final_appcast_record != appcast_record
            or final_appcast_data != appcast_data
            or final_checksums_record != checksums_record
            or final_checksums_data != checksums_data
            or final_app_archive_record != app_archive_record
            or final_archive_container_record != archive_container_record
            or final_updates_subjects != updates_subjects
        ):
            raise GateError("candidate artifacts changed during Sparkle verification")

        records = [
            architecture_record,
            dmg_record,
            app_archive_record,
            archive_container_record,
            appcast_record,
            sbom_record,
            release_notes_record,
            checksums_record,
            app_receipt_record,
            archive_receipt_record,
            app_notary_record,
            dmg_notary_record,
            *updates_subjects,
        ]
        paths: dict[str, dict] = {}
        for record in records:
            existing = paths.get(record["path"])
            if existing is not None and existing != record:
                raise GateError("candidate-stage inputs disagree about duplicate evidence paths")
            paths[record["path"]] = record

        manifest = {
            "schemaVersion": 1,
            "manifestKind": "candidateStageEvidence",
            "visibility": "private",
            "stage": {
                "name": "candidate",
                "decision": "noGo",
                "promotionStatus": "pending",
                "verifyFilesRequired": True,
            },
            "candidate": {
                "version": args.candidate_version,
                "build": args.build,
                "tag": args.tag,
                "commit": args.commit,
            },
            "freeze": {"architecture": architecture_record},
            "artifacts": {
                "dmg": dmg_record,
                "appArchive": app_archive_record,
                "archiveContainer": archive_container_record,
                "appcast": appcast_record,
                "sbom": sbom_record,
                "signedReleaseNotes": release_notes_record,
                "updatesRoot": updates_root,
                "updatesChecksums": checksums_record,
                "updatesSubjects": updates_subjects,
            },
            "receipts": {
                "app": app_receipt_record,
                "archive": archive_receipt_record,
                "archiveDirectory": archive_directory_relative,
                "notarization": {"app": app_notary, "dmg": dmg_notary},
            },
            "signing": {
                "certificateSHA256": certificate_sha256,
                "sparkleVerification": sparkle_verification,
            },
        }
        validate_schema(manifest, "candidate-stage-evidence.schema.json")
        reject_placeholders(manifest, label="candidate-stage evidence")
        write_private_json(Path(args.output), evidence_root, manifest)
        print(Path(args.output))
        return 0
    except (GateError, OSError, KeyError, TypeError, ValueError) as error:
        return main_error(error)


if __name__ == "__main__":
    raise SystemExit(main())
