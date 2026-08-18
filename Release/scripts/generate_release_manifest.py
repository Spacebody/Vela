#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


class ManifestError(ValueError):
    pass


def run(*args: str) -> str:
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()


def load_json(path: Path) -> dict:
    if not path.is_file() or path.is_symlink():
        raise ManifestError(f"expected a regular JSON file: {path}")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ManifestError(f"expected a JSON object: {path}")
    return value


def sha256(path: Path) -> str:
    if not path.is_file() or path.is_symlink():
        raise ManifestError(f"expected a regular artifact: {path}")
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_build(value: int) -> None:
    raw = str(value)
    if re.fullmatch(r"20[0-9]{8}", raw) is None:
        raise ManifestError("build must use the 10-digit YYYYMMDDNN strategy")
    try:
        datetime.strptime(raw[:8], "%Y%m%d")
    except ValueError as error:
        raise ManifestError("build contains an invalid YYYYMMDD date") from error
    if raw[8:] == "00":
        raise ManifestError("build sequence NN must be between 01 and 99")


def write_immutable_json(path: Path, value: dict) -> None:
    if path.exists() or path.is_symlink():
        raise ManifestError(f"refusing to overwrite immutable manifest: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o644)
        try:
            os.link(temporary, path)
        except FileExistsError as error:
            raise ManifestError(f"manifest appeared concurrently; refusing overwrite: {path}") from error
    finally:
        if temporary.exists():
            temporary.unlink()


def notary_summary(path: Path | None) -> dict | None:
    if path is None:
        return None
    value = load_json(path)
    identifier = value.get("id")
    status = value.get("status")
    if not isinstance(identifier, str) or not identifier or status != "Accepted":
        raise ManifestError(f"notary receipt is not Accepted: {path}")
    return {"submissionID": identifier, "status": status}


def bundle_components(compatibility: dict) -> dict:
    """Encode optional component values the same way Swift Codable does."""
    configured = compatibility["components"]
    return {
        name: configured[name]
        for name in ("mihomo", "sparkle", "helper", "cli")
        if configured.get(name) is not None
    }


def bundle_protocols(compatibility: dict) -> dict:
    """Flatten protocol ranges to ReleaseManifest.Protocols.CodingKeys."""
    helper = compatibility["helperProtocol"]
    result = {
        "helperMinimum": helper["minimum"],
        "helperMaximum": helper["maximum"],
    }
    for prefix, config_key in (
        ("automation", "automationProtocol"),
        ("cli", "cliProtocol"),
    ):
        configured = compatibility.get(config_key)
        if configured is not None:
            result[f"{prefix}Minimum"] = configured["minimum"]
            result[f"{prefix}Maximum"] = configured["maximum"]
    return result


def bundle_schemas(compatibility: dict) -> dict:
    """Translate release config names to ReleaseManifest.Schemas keys."""
    configured = compatibility["schemas"]
    result = {
        "data": configured["rootData"],
        "profiles": configured["profile"],
        "configuration": configured["configuration"],
        "updateJournal": configured["updateJournal"],
    }
    if configured.get("scene") is not None:
        result["scene"] = configured["scene"]
    return result


def main() -> int:
    default_root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description="Generate a Vela bundle or external release manifest")
    parser.add_argument("--repository-root", default=str(default_root))
    parser.add_argument("--config", default="Release/config/release.json")
    parser.add_argument("--kind", choices=["bundle", "external"], required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True, type=int)
    parser.add_argument("--channel", choices=["stable", "beta"], required=True)
    parser.add_argument("--tag")
    parser.add_argument("--prerelease-label")
    parser.add_argument("--output", required=True)
    parser.add_argument("--app")
    parser.add_argument("--app-zip")
    parser.add_argument("--dmg")
    parser.add_argument("--appcast")
    parser.add_argument("--app-notary-receipt")
    parser.add_argument("--dmg-notary-receipt")
    parser.add_argument("--signing-certificate-sha256")
    parser.add_argument("--signing-certificate-serial")
    parser.add_argument("--allow-dirty", action="store_true")
    args = parser.parse_args()

    try:
        root = Path(args.repository_root).resolve()
        config_path = Path(args.config)
        if not config_path.is_absolute():
            config_path = root / config_path
        config = load_json(config_path)
        product = config["product"]
        configured_version = config["versioning"]["marketingVersion"]
        if args.version != configured_version:
            raise ManifestError(
                f"version {args.version} differs from configured release version {configured_version}"
            )
        validate_build(args.build)
        if args.channel == "stable" and args.prerelease_label:
            raise ManifestError("Stable manifests may not have a prerelease label")
        if args.channel == "beta" and not args.prerelease_label:
            raise ManifestError("Beta manifests require --prerelease-label")

        dirty = bool(run("git", "-C", str(root), "status", "--porcelain"))
        if dirty and not args.allow_dirty:
            raise ManifestError("refusing to generate a release manifest from dirty source")
        commit = run("git", "-C", str(root), "rev-parse", "HEAD")
        if re.fullmatch(r"[0-9a-f]{40}", commit) is None:
            raise ManifestError("Git commit is not a full SHA-1")
        exact_tags = run("git", "-C", str(root), "tag", "--points-at", "HEAD").splitlines()
        tag = args.tag or (exact_tags[0] if len(exact_tags) == 1 else None)
        if not isinstance(tag, str) or not tag.strip():
            raise ManifestError("manifest requires a non-empty --tag")
        if not args.allow_dirty:
            if not tag or tag not in exact_tags:
                raise ManifestError("production manifest requires an explicit tag pointing at HEAD")

        paths = config["paths"]
        package_resolved = root / paths["packageResolved"]
        mihomo_manifest_path = root / paths["mihomoManifest"]
        compatibility = load_json(root / paths["compatibility"])
        mihomo_manifest = load_json(mihomo_manifest_path)
        if mihomo_manifest.get("version") != product["mihomoVersion"]:
            raise ManifestError("Mihomo manifest version differs from release config")
        if mihomo_manifest.get("architecture") != product["architecture"]:
            raise ManifestError("Mihomo manifest architecture differs from release config")

        xcode_lines = run("xcodebuild", "-version").splitlines()
        swift_line = run("swift", "--version").splitlines()[0]
        sdk = run("xcrun", "--sdk", "macosx", "--show-sdk-version")
        public_key = config["updates"]["publicEDKey"]
        public_key_fingerprint = None
        if "__" not in public_key:
            try:
                decoded_key = base64.b64decode(public_key, validate=True)
            except ValueError as error:
                raise ManifestError("configured Sparkle public key is invalid base64") from error
            if len(decoded_key) != 32:
                raise ManifestError("configured Sparkle public key is not 32 bytes")
            public_key_fingerprint = hashlib.sha256(decoded_key).hexdigest()

        created_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        package_resolved_sha256 = sha256(package_resolved)
        host_architecture = run("uname", "-m")

        if args.kind == "bundle":
            if any(
                value is not None
                for value in [
                    args.app,
                    args.app_zip,
                    args.dmg,
                    args.appcast,
                    args.app_notary_receipt,
                    args.dmg_notary_receipt,
                    args.signing_certificate_sha256,
                    args.signing_certificate_serial,
                ]
            ):
                raise ManifestError(
                    "bundle manifest must not contain external artifact, notarization, or trust data"
                )
            # This object intentionally mirrors BuildManifestReader's strict
            # nine-key schema. Do not add provenance extensions here: the
            # bundled file is decoded by the App and protected by its code
            # signature. Richer release provenance belongs in the external
            # manifest generated after notarization.
            manifest: dict = {
                "schemaVersion": 1,
                "app": {
                    "version": args.version,
                    "build": args.build,
                    "channel": args.channel,
                    "prereleaseLabel": args.prerelease_label,
                    "bundleIdentifier": product["bundleIdentifier"],
                },
                "build": {
                    "createdAtUTC": created_at,
                    "sourceDirty": dirty,
                },
                "platform": {
                    "minimumMacOS": product["minimumMacOS"],
                    "architectures": [product["architecture"]],
                },
                "components": bundle_components(compatibility),
                "protocols": bundle_protocols(compatibility),
                "schemas": bundle_schemas(compatibility),
                "source": {
                    "commit": commit,
                    "tag": tag,
                    "packageResolvedSHA256": package_resolved_sha256,
                },
                "toolchain": {
                    "xcode": xcode_lines[0].removeprefix("Xcode "),
                    "swift": swift_line,
                    "sdk": sdk,
                    "hostArchitecture": host_architecture,
                },
            }
        else:
            # The external manifest is not decoded by BuildManifestReader and
            # may retain richer provenance and trust evidence. Bind it to the
            # exact reviewed architecture-freeze bytes; the bundled manifest
            # above intentionally remains the App's strict nine-key schema.
            architecture_freeze_path = root / "Hardening/config/architecture-freeze.json"
            manifest = {
                "schemaVersion": 1,
                "manifestKind": "external",
                "app": {
                    "name": product["name"],
                    "version": args.version,
                    "build": args.build,
                    "channel": args.channel,
                    "prereleaseLabel": args.prerelease_label,
                    "bundleIdentifier": product["bundleIdentifier"],
                },
                "build": {
                    "createdAtUTC": created_at,
                    "sourceDirty": dirty,
                    "buildID": os.environ.get("GITHUB_RUN_ID", "local"),
                },
                "platform": {
                    "minimumMacOS": product["minimumMacOS"],
                    "architectures": [product["architecture"]],
                },
                "components": compatibility["components"],
                "protocols": {
                    "helper": compatibility["helperProtocol"],
                    "automation": compatibility.get("automationProtocol"),
                    "cli": compatibility.get("cliProtocol"),
                },
                "schemas": compatibility["schemas"],
                "source": {
                    "commit": commit,
                    "tag": tag,
                    "packageResolvedSHA256": package_resolved_sha256,
                    "mihomoManifestSHA256": sha256(mihomo_manifest_path),
                    "mihomoArchiveSHA256": mihomo_manifest.get("archiveSHA256"),
                    "architectureFreezeSHA256": sha256(architecture_freeze_path),
                },
                "toolchain": {
                    "xcode": xcode_lines[0].removeprefix("Xcode "),
                    "xcodeBuild": xcode_lines[1].removeprefix("Build version "),
                    "swift": swift_line,
                    "sdk": sdk,
                    "hostArchitecture": host_architecture,
                },
                "trust": {
                    "teamIdentifier": product["teamIdentifier"],
                    "sparklePublicKeySHA256": public_key_fingerprint,
                    "signingCertificateSHA256": args.signing_certificate_sha256,
                    "signingCertificateSerial": args.signing_certificate_serial,
                },
            }
            required_artifacts = {
                "appZip": args.app_zip,
                "dmg": args.dmg,
                "appcast": args.appcast,
            }
            missing = [name for name, value in required_artifacts.items() if value is None]
            if missing:
                raise ManifestError(f"external manifest is missing artifacts: {missing}")
            manifest["artifacts"] = {
                name: {
                    "filename": Path(value).name,
                    "sha256": sha256(Path(value)),
                    "size": Path(value).stat().st_size,
                }
                for name, value in required_artifacts.items()
                if value is not None
            }
            if args.app is not None:
                app_path = Path(args.app)
                if not app_path.is_dir() or app_path.is_symlink() or app_path.suffix != ".app":
                    raise ManifestError("--app must be a regular App bundle")
                manifest["appBundle"] = {"name": app_path.name}
            manifest["notarization"] = {
                "app": notary_summary(
                    Path(args.app_notary_receipt) if args.app_notary_receipt else None
                ),
                "dmg": notary_summary(
                    Path(args.dmg_notary_receipt) if args.dmg_notary_receipt else None
                ),
            }
            if not args.allow_dirty and (
                manifest["notarization"]["app"] is None
                or manifest["notarization"]["dmg"] is None
            ):
                raise ManifestError("production external manifest requires App and DMG notary receipts")

        serialized = json.dumps(manifest, sort_keys=True)
        if re.search(r"/Users/|keychain|PRIVATE KEY|Authorization:", serialized, re.IGNORECASE):
            raise ManifestError("manifest contains forbidden machine-local or secret material")
        output = Path(args.output)
        write_immutable_json(output, manifest)
        print(f"Generated {args.kind} release manifest: {output}")
        return 0
    except (
        OSError,
        KeyError,
        IndexError,
        UnicodeError,
        json.JSONDecodeError,
        subprocess.CalledProcessError,
        ManifestError,
    ) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
