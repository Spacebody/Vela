#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
from datetime import datetime
from pathlib import Path

from _common import (
    GateError,
    load_json,
    main_error,
    parse_semver,
    valid_sha256,
    validate_build_number,
    validate_schema,
)


def validate_published(value: dict) -> tuple[set[int], set[str], list[int]]:
    validate_schema(value, "published-builds.schema.json")
    builds: set[int] = set()
    finalized_versions: set[str] = set()
    rc_builds: list[int] = []
    version_statuses: dict[str, list[str]] = {}
    for item in value["builds"]:
        build = item["build"]
        version = item["version"]
        if build in builds:
            raise GateError(f"build-ledger allocation is duplicated: {build}")
        validate_build_number(build)
        base, prerelease = parse_semver(version)
        del base
        if item["channel"] == "rc":
            if prerelease is None or re.fullmatch(r"rc\.[1-9][0-9]*", prerelease) is None:
                raise GateError(f"build-ledger RC has invalid version: {version}")
            rc_builds.append(build)
        elif prerelease is not None:
            raise GateError(f"build-ledger Stable has a prerelease version: {version}")
        artifact_sha = item["artifactSHA256"]
        recorded_at = datetime.fromisoformat(item["recordedAt"].replace("Z", "+00:00"))
        status_updated_at = datetime.fromisoformat(item["statusUpdatedAt"].replace("Z", "+00:00"))
        if status_updated_at < recorded_at:
            raise GateError(f"build-ledger status update predates allocation: {build}")
        if item["status"] == "allocated" and (
            artifact_sha is not None or status_updated_at != recorded_at
        ):
            raise GateError(f"allocated build must have no artifact and unchanged status time: {build}")
        if item["status"] == "published":
            if not valid_sha256(artifact_sha):
                raise GateError(f"published artifact SHA-256 is invalid: {version}")
        elif artifact_sha is not None and not valid_sha256(artifact_sha):
            raise GateError(f"non-published artifact SHA-256 is invalid: {version}")
        if item["status"] == "withdrawn" and not valid_sha256(artifact_sha):
            raise GateError(f"withdrawn artifact SHA-256 is required: {version}")
        if item["status"] in {"published", "withdrawn"}:
            if version in finalized_versions:
                raise GateError(f"build-ledger finalized version is duplicated: {version}")
            finalized_versions.add(version)
        version_statuses.setdefault(version, []).append(item["status"])
        builds.add(build)
    for version, statuses in version_statuses.items():
        if statuses.count("allocated") > 1:
            raise GateError(f"build-ledger has multiple active allocations for version: {version}")
        if "allocated" in statuses and any(
            status in {"published", "withdrawn"} for status in statuses
        ):
            raise GateError(f"build-ledger mixes active and finalized rows for version: {version}")
    return builds, finalized_versions, rc_builds


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate Vela RC/Stable SemVer and build monotonicity")
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", type=int, required=True)
    parser.add_argument("--published", required=True)
    parser.add_argument("--channel", choices=["rc", "stable"], required=True)
    parser.add_argument("--tag")
    parser.add_argument("--marketing-version")
    parser.add_argument("--require-history", action="store_true")
    parser.add_argument(
        "--expect-reserved",
        action="store_true",
        help="require this exact candidate to be the current allocated high-water row",
    )
    args = parser.parse_args()
    try:
        base, prerelease = parse_semver(args.version)
        validate_build_number(args.build)
        if args.channel == "rc":
            if prerelease is None or re.fullmatch(r"rc\.[1-9][0-9]*", prerelease) is None:
                raise GateError("RC version must use 1.0.0-rc.N with N greater than zero")
        elif prerelease is not None:
            raise GateError("Stable version must not contain a prerelease identifier")
        if args.marketing_version is not None and args.marketing_version != base:
            raise GateError("marketing version differs from the candidate SemVer base")
        if args.tag is not None and args.tag != f"v{args.version}":
            raise GateError(f"tag must be v{args.version}")

        published = load_json(Path(args.published), label="published build registry")
        builds, finalized_versions, rc_builds = validate_published(published)
        if args.require_history and not builds:
            raise GateError("protected release requires immutable build-ledger/high-water evidence")
        if args.expect_reserved:
            matches = [item for item in published["builds"] if item["build"] == args.build]
            if len(matches) != 1:
                raise GateError("candidate build lacks an exact protected allocation")
            reservation = matches[0]
            expected = {
                "version": args.version,
                "build": args.build,
                "channel": args.channel,
                "status": "allocated",
            }
            actual = {key: reservation[key] for key in expected}
            if actual != expected:
                raise GateError("candidate build allocation identity/status differs from release request")
            maximum = max(builds, default=0)
            if args.build != maximum:
                raise GateError(
                    f"candidate allocation {args.build} is not build-ledger high-water {maximum}"
                )
            print(f"SemVer/build reservation gate passed: {args.version} ({args.build}) {args.channel}")
            return 0
        if any(
            item["version"] == args.version and item["status"] == "allocated"
            for item in published["builds"]
        ):
            raise GateError(f"version already has an active build allocation: {args.version}")
        if args.build in builds:
            raise GateError(f"build was already allocated, failed, withdrawn, or published: {args.build}")
        if args.version in finalized_versions:
            raise GateError(f"version was already published or withdrawn: {args.version}")
        maximum = max(builds, default=0)
        if args.build <= maximum:
            raise GateError(f"build {args.build} must be greater than build-ledger high-water {maximum}")
        if args.channel == "stable" and rc_builds and args.build <= max(rc_builds):
            raise GateError("Stable build must be greater than every allocated RC build")
        print(f"SemVer/build gate passed: {args.version} ({args.build}) {args.channel}")
        return 0
    except (GateError, OSError, KeyError, TypeError, ValueError) as error:
        return main_error(error)


if __name__ == "__main__":
    raise SystemExit(main())
