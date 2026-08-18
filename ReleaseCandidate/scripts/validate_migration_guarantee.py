#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
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


EXPECTED_VERSIONS = {f"0.{index}" for index in range(1, 9)}
EXPECTED_STORES = {
    "profileMetadata",
    "localRawConfigurations",
    "remoteRawConfigurations",
    "profileRevisions",
    "configurationOverrides",
    "configurationLayers",
    "ruleLayers",
    "scenes",
    "ssidSecretReferences",
    "appSettings",
    "helperSettings",
    "appUpdateStore",
    "appUpdateJournal",
    "userCoreStore",
    "rootCoreStore",
    "rootCoreInstallJournal",
    "rootRuntimeJournal",
    "cliInstallMetadata",
    "onboardingState",
    "helpState",
    "reliabilityEvidence",
}
REQUIRED_GUARANTEES = {
    "backupBeforeMutation",
    "atomicCommit",
    "idempotent",
    "noSilentDataLoss",
    "keychainSecretsRemainInKeychain",
    "newerSchemaWriteGuard",
    "safeModeOnFailure",
}
PROVENANCE_FIELDS = (
    "producingTag",
    "producingCommit",
    "fixturePath",
    "fixtureSHA256",
    "generatorVersion",
    "fixtureSchemaVersion",
)


def expected_tag_version(version: str, tag: str) -> bool:
    return re.fullmatch(rf"v{re.escape(version)}(?:\.0)?", tag) is not None


def verify_git_source(root: Path, source: dict) -> None:
    version = source["version"]
    tag = source["producingTag"]
    commit = source["producingCommit"]
    if not isinstance(tag, str) or not expected_tag_version(version, tag):
        raise GateError(f"{version}: producing tag must be v{version} or v{version}.0")
    if not valid_commit(commit):
        raise GateError(f"{version}: producing commit is missing or invalid")
    git_output(root, "cat-file", "-e", f"{commit}^{{commit}}")
    ref = f"refs/tags/{tag}"
    if git_output(root, "cat-file", "-t", ref) != "tag":
        raise GateError(f"{version}: producing tag must be annotated")
    tag_commit = git_output(root, "rev-parse", f"{ref}^{{commit}}")
    if tag_commit != commit:
        raise GateError(f"{version}: producing tag does not bind the declared commit")
    git_output(root, "verify-tag", ref)


def verify_fixture_metadata(path: Path, source: dict) -> None:
    fixture = load_json(path, label="historical fixture")
    metadata = fixture.get("fixtureMetadata")
    if not isinstance(metadata, dict):
        raise GateError(f"{source['version']}: fixture lacks fixtureMetadata")
    expected = {
        "sourceVersion": source["version"],
        "producingTag": source["producingTag"],
        "producingCommit": source["producingCommit"],
        "generatorVersion": source["generatorVersion"],
        "fixtureSchemaVersion": source["fixtureSchemaVersion"],
    }
    if metadata != expected:
        raise GateError(f"{source['version']}: fixture metadata does not match declared provenance")


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate the V0.1 through V0.8 migration guarantee")
    parser.add_argument("manifest")
    parser.add_argument("--allow-pending", action="store_true")
    parser.add_argument("--repository-root", default=".")
    parser.add_argument("--verify-files", action="store_true")
    args = parser.parse_args()
    try:
        value = load_json(Path(args.manifest), label="migration guarantee")
        validate_schema(value, "migration-guarantee.schema.json")
        reject_forbidden_text(value, label="migration guarantee")
        versions = [source["version"] for source in value["sources"]]
        if set(versions) != EXPECTED_VERSIONS or len(versions) != len(EXPECTED_VERSIONS):
            raise GateError("migration sources must contain each version from 0.1 through 0.8 exactly once")
        stores = [store["id"] for store in value["stores"]]
        if set(stores) != EXPECTED_STORES or len(stores) != len(EXPECTED_STORES):
            raise GateError("migration store/journal inventory is incomplete, duplicated, or unreviewed")
        if set(value["guarantees"]) != REQUIRED_GUARANTEES:
            raise GateError("migration guarantee set is incomplete or contains an unreviewed value")

        errors: list[str] = []
        incomplete: list[str] = []
        root = Path(args.repository_root)
        for source in value["sources"]:
            status = source["status"]
            fields = tuple(source[field] for field in PROVENANCE_FIELDS)
            if status == "passed":
                if not isinstance(source["producingTag"], str) or not expected_tag_version(
                    source["version"], source["producingTag"]
                ):
                    errors.append(
                        f"{source['version']}: producing tag must be v{source['version']} or v{source['version']}.0"
                    )
                if not valid_commit(source["producingCommit"]):
                    errors.append(f"{source['version']}: producing commit is missing or invalid")
                if not isinstance(source["fixturePath"], str) or not source["fixturePath"]:
                    errors.append(f"{source['version']}: fixture path is missing")
                if not valid_sha256(source["fixtureSHA256"]):
                    errors.append(f"{source['version']}: fixture SHA-256 is missing or invalid")
                if not isinstance(source["generatorVersion"], str) or not source["generatorVersion"]:
                    errors.append(f"{source['version']}: generator version is missing")
                if not isinstance(source["fixtureSchemaVersion"], int):
                    errors.append(f"{source['version']}: fixture schema version is missing")
                if args.verify_files and all(field is not None for field in fields):
                    try:
                        fixture_path = checked_evidence(root, source["fixturePath"], source["fixtureSHA256"])
                        verify_fixture_metadata(fixture_path, source)
                        verify_git_source(root, source)
                    except GateError as error:
                        errors.append(f"{source['version']}: {error}")
            elif any(field is not None for field in fields):
                errors.append(f"{source['version']}: non-passed source must not carry unverified fixture provenance")
            if status != "passed":
                incomplete.append(f"{source['version']}: {status}")

        for store in value["stores"]:
            status = store["status"]
            if status == "passed":
                if not isinstance(store["path"], str) or not valid_sha256(store["sha256"]):
                    errors.append(f"store {store['id']}: passed evidence lacks path/SHA-256")
                elif args.verify_files:
                    try:
                        checked_evidence(root, store["path"], store["sha256"])
                    except GateError as error:
                        errors.append(f"store {store['id']}: {error}")
            else:
                if store["path"] is not None or store["sha256"] is not None:
                    errors.append(
                        f"store {store['id']}: non-passed coverage must not carry unverified provenance"
                    )
                incomplete.append(f"store {store['id']}: {status}")

        for name, evidence in value["evidence"].items():
            if evidence["status"] == "passed":
                if not isinstance(evidence["path"], str) or not valid_sha256(evidence["sha256"]):
                    errors.append(f"{name}: passed evidence lacks path/SHA-256")
                elif args.verify_files:
                    try:
                        checked_evidence(root, evidence["path"], evidence["sha256"])
                    except GateError as error:
                        errors.append(f"{name}: {error}")
            else:
                if evidence["path"] is not None or evidence["sha256"] is not None:
                    errors.append(f"{name}: pending/failed evidence must not carry unverified provenance")
                incomplete.append(f"{name}: {evidence['status']}")

        if errors:
            raise GateError("migration guarantee is malformed:\n- " + "\n- ".join(errors))
        if incomplete:
            if not args.allow_pending:
                raise GateError("migration guarantee is not closed:\n- " + "\n- ".join(incomplete))
            if value["decision"] != "noGo" or not value["blockers"]:
                raise GateError("incomplete migration evidence must remain an explicit No-Go with blockers")
            print(f"Migration structure is valid and truthfully No-Go ({len(incomplete)} incomplete checks).")
            return 0
        if value["decision"] != "go" or value["blockers"]:
            raise GateError("passed migration evidence requires decision=go and no blockers")
        print("Migration guarantee passed for V0.1 through V0.8.")
        return 0
    except (GateError, OSError, KeyError, TypeError, ValueError) as error:
        return main_error(error)


if __name__ == "__main__":
    raise SystemExit(main())
