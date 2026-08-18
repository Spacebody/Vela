#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import sys
from pathlib import Path

from core_release_lib import (
    CoreReleaseError,
    atomic_write,
    canonical_json_bytes,
    load_json,
    read_regular_bytes,
    sha256_bytes,
    validate_compatibility,
    validate_seed,
)


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate fixed signed Core bundle metadata/resources")
    parser.add_argument("--seed", required=True)
    parser.add_argument("--compatibility-report", required=True)
    parser.add_argument("--dedicated-host-evidence")
    parser.add_argument("--performance-review")
    parser.add_argument("--license", required=True)
    parser.add_argument("--bundle-identifier", required=True)
    parser.add_argument("--package-revision", type=int, required=True)
    parser.add_argument("--output-directory", required=True)
    parser.add_argument("--production", action="store_true")
    args = parser.parse_args()
    try:
        if re.fullmatch(r"[A-Za-z0-9.-]+\.MihomoCore", args.bundle_identifier) is None:
            raise CoreReleaseError("Core bundle identifier must be the stable main-bundle .MihomoCore identifier")
        if args.package_revision < 1:
            raise CoreReleaseError("Core package revision must be positive")
        seed = validate_seed(load_json(Path(args.seed), maximum=64 * 1024))
        compatibility_path = Path(args.compatibility_report)
        compatibility_raw = read_regular_bytes(compatibility_path, maximum=1024 * 1024)
        compatibility = validate_compatibility(
            json.loads(compatibility_raw),
            production=args.production,
            dedicated_host_evidence=(
                Path(args.dedicated_host_evidence)
                if args.dedicated_host_evidence
                else None
            ),
            performance_review=(
                Path(args.performance_review) if args.performance_review else None
            ),
        )
        core_id = f"{seed['version']}-r{args.package_revision}"
        if compatibility["coreID"] != core_id:
            raise CoreReleaseError("compatibility report coreID differs from seed/revision")
        license_raw = read_regular_bytes(Path(args.license), maximum=1024 * 1024)
        if b"GNU GENERAL PUBLIC LICENSE" not in license_raw or b"Version 3" not in license_raw:
            raise CoreReleaseError("Mihomo license material does not appear to contain GPL version 3")
        output = Path(args.output_directory)
        if output.exists() or output.is_symlink():
            raise CoreReleaseError("refusing to overwrite Core resource staging")
        output.mkdir(parents=True, mode=0o700)
        resources = output / "Resources"
        resources.mkdir(mode=0o700)
        version_without_v = seed["version"].removeprefix("v")
        info = {
            "CFBundleIdentifier": args.bundle_identifier,
            "CFBundleName": "Vela Mihomo Core",
            "CFBundlePackageType": "BNDL",
            "CFBundleExecutable": "mihomo",
            "CFBundleShortVersionString": version_without_v,
            "CFBundleVersion": str(args.package_revision),
            "LSMinimumSystemVersion": "15.0",
            "VelaCoreVersion": seed["version"],
            "VelaCorePackageRevision": args.package_revision,
            "VelaCoreArchitecture": "arm64",
        }
        info_bytes = plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=True)
        source = {
            "schemaVersion": 1,
            "coreID": core_id,
            "upstreamRepository": "https://github.com/MetaCubeX/mihomo",
            "upstreamTag": seed["tag"],
            "upstreamCommit": seed["commit"],
            "upstreamAssetName": seed["assetName"],
            "upstreamAssetURL": seed["assetURL"],
            "upstreamArchiveSHA256": seed["archiveSHA256"],
            "upstreamArchiveSizeBytes": seed["archiveSizeBytes"],
            "correspondingSourceURL": seed["sourceURL"],
            "license": "GPL-3.0-only",
            "licenseURL": seed["licenseURL"],
            "velaModifiedUpstreamSource": False,
            "velaCorePackageRevision": args.package_revision,
        }
        upstream_payload_sha = compatibility.get("artifacts", {}).get(
            "upstreamPayloadSHA256"
        )
        if upstream_payload_sha is not None:
            source["upstreamPayloadSHA256"] = upstream_payload_sha
        notice = f"""# Vela Mihomo Core Notice

This bundle redistributes Mihomo {seed['version']} from https://github.com/MetaCubeX/mihomo under GPL-3.0-only.

- Exact upstream tag: {seed['tag']}
- Exact upstream commit: {seed['commit']}
- Official asset: {seed['assetName']}
- Official archive SHA-256: {seed['archiveSHA256']}
- Corresponding source: {seed['sourceURL']}
- Vela package revision: {args.package_revision}
- Modification status: Vela does not modify the upstream Mihomo source or executable bytes before signing.

Vela re-signs the unmodified arm64 executable solely for macOS distribution. The Mihomo project does not endorse Vela.
"""
        atomic_write(output / "Info.plist", info_bytes)
        atomic_write(resources / "LICENSE", license_raw)
        atomic_write(resources / "NOTICE.md", notice.encode("utf-8"))
        atomic_write(resources / "source.json", canonical_json_bytes(source))
        atomic_write(resources / "compatibility.json", compatibility_raw)
        for path in [output / "Info.plist", *resources.iterdir()]:
            os.chmod(path, 0o644)
        print(f"Generated Core resources: coreID={core_id} compatibilitySHA256={sha256_bytes(compatibility_raw)}")
        return 0
    except (OSError, UnicodeError, json.JSONDecodeError, CoreReleaseError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
