#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import sys
from datetime import datetime
from pathlib import Path


BUNDLE_KEYS = {
    "schemaVersion",
    "app",
    "build",
    "platform",
    "components",
    "protocols",
    "schemas",
    "source",
    "toolchain",
}
EXTERNAL_KEYS = BUNDLE_KEYS | {
    "manifestKind",
    "trust",
    "artifacts",
    "notarization",
}


class ManifestValidationError(ValueError):
    pass


def load_json(path: Path) -> dict:
    if not path.is_file() or path.is_symlink():
        raise ManifestValidationError(f"expected a regular manifest file: {path}")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ManifestValidationError("manifest must be a JSON object")
    return value


def sha256(path: Path) -> str:
    if not path.is_file() or path.is_symlink():
        raise ManifestValidationError(f"expected a regular artifact: {path}")
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_object(parent: dict, key: str) -> dict:
    value = parent.get(key)
    if not isinstance(value, dict):
        raise ManifestValidationError(f"{key} must be an object")
    return value


def exact_keys(value: dict, expected: set[str], label: str) -> None:
    actual = set(value)
    if actual != expected:
        raise ManifestValidationError(
            f"{label} keys differ; missing={sorted(expected - actual)}, "
            f"extra={sorted(actual - expected)}"
        )


def allowed_keys(
    value: dict,
    required: set[str],
    allowed: set[str],
    label: str,
) -> None:
    actual = set(value)
    missing = required - actual
    extra = actual - allowed
    if missing or extra:
        raise ManifestValidationError(
            f"{label} keys differ; missing={sorted(missing)}, extra={sorted(extra)}"
        )


def positive_integer(value: object, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise ManifestValidationError(f"{label} must be a positive integer")
    return value


def nonempty_string(value: object, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ManifestValidationError(f"{label} must be a non-empty string")
    return value


def validate_timestamp(value: object) -> None:
    raw = nonempty_string(value, "build.createdAtUTC")
    if not raw.endswith("Z"):
        raise ManifestValidationError("build.createdAtUTC must be an explicit UTC timestamp")
    try:
        datetime.fromisoformat(raw[:-1] + "+00:00")
    except ValueError as error:
        raise ManifestValidationError("build.createdAtUTC is invalid") from error


def validate_app(app: dict, *, external: bool) -> None:
    expected = {
        "version",
        "build",
        "channel",
        "prereleaseLabel",
        "bundleIdentifier",
    }
    if external:
        expected.add("name")
    exact_keys(app, expected, "app")
    if external and app.get("name") != "Vela":
        raise ManifestValidationError("external manifest App name is invalid")
    if app.get("bundleIdentifier") != "dev.yilin.Vela":
        raise ManifestValidationError("manifest App bundle identifier is invalid")
    if re.fullmatch(r"\d+\.\d+\.\d+", str(app.get("version", ""))) is None:
        raise ManifestValidationError("manifest App version is invalid")
    positive_integer(app.get("build"), "app.build")
    channel = app.get("channel")
    prerelease = app.get("prereleaseLabel")
    if channel not in {"stable", "beta"}:
        raise ManifestValidationError("manifest channel is invalid")
    if channel == "stable" and prerelease is not None:
        raise ManifestValidationError("Stable manifest may not have a prerelease label")
    if channel == "beta" and not isinstance(prerelease, str):
        raise ManifestValidationError("Beta manifest requires a prerelease label")


def validate_build_object(build: dict, *, external: bool) -> None:
    expected = {"createdAtUTC", "sourceDirty"}
    if external:
        expected.add("buildID")
    exact_keys(build, expected, "build")
    validate_timestamp(build.get("createdAtUTC"))
    if not isinstance(build.get("sourceDirty"), bool):
        raise ManifestValidationError("build.sourceDirty must be Boolean")
    if external:
        nonempty_string(build.get("buildID"), "build.buildID")


def validate_platform(platform: dict) -> None:
    exact_keys(platform, {"minimumMacOS", "architectures"}, "platform")
    if platform.get("minimumMacOS") != "15.0" or platform.get("architectures") != ["arm64"]:
        raise ManifestValidationError("manifest platform must be macOS 15 / arm64")


def validate_components(components: dict, *, external: bool, production: bool) -> None:
    required = {"mihomo", "sparkle", "helper"}
    allowed = required | {"cli"}
    if external:
        exact_keys(components, allowed, "components")
    else:
        allowed_keys(components, required, allowed, "components")
    if components.get("mihomo") != "v1.19.29" or components.get("sparkle") != "2.9.4":
        raise ManifestValidationError("manifest component versions drifted")
    for name in ("helper", "cli"):
        value = components.get(name)
        if value is not None and re.fullmatch(r"\d+\.\d+\.\d+", str(value)) is None:
            raise ManifestValidationError(f"components.{name} is invalid")
    if production and components.get("cli") is None:
        raise ManifestValidationError("production manifest has no CLI component version")


def validate_range(minimum: object, maximum: object, label: str) -> None:
    lower = positive_integer(minimum, f"{label}Minimum")
    upper = positive_integer(maximum, f"{label}Maximum")
    if upper < lower:
        raise ManifestValidationError(f"{label} protocol maximum precedes minimum")


def validate_bundle_protocols(protocols: dict, *, production: bool) -> None:
    required = {"helperMinimum", "helperMaximum"}
    allowed = required | {
        "automationMinimum",
        "automationMaximum",
        "cliMinimum",
        "cliMaximum",
    }
    allowed_keys(protocols, required, allowed, "protocols")
    validate_range(protocols["helperMinimum"], protocols["helperMaximum"], "helper")
    for prefix in ("automation", "cli"):
        minimum = f"{prefix}Minimum"
        maximum = f"{prefix}Maximum"
        present = (minimum in protocols, maximum in protocols)
        if present[0] != present[1]:
            raise ManifestValidationError(f"{prefix} protocol requires minimum and maximum")
        if present[0]:
            validate_range(protocols[minimum], protocols[maximum], prefix)
        elif production:
            raise ManifestValidationError(f"production manifest has no {prefix} protocol")


def validate_external_protocols(protocols: dict, *, production: bool) -> None:
    exact_keys(protocols, {"helper", "automation", "cli"}, "protocols")
    for name in ("helper", "automation", "cli"):
        value = protocols.get(name)
        if value is None:
            if name == "helper" or production:
                raise ManifestValidationError(f"external manifest has no {name} protocol")
            continue
        if not isinstance(value, dict):
            raise ManifestValidationError(f"protocols.{name} must be an object or null")
        exact_keys(value, {"minimum", "maximum"}, f"protocols.{name}")
        validate_range(value["minimum"], value["maximum"], name)


def validate_bundle_schemas(schemas: dict, *, production: bool) -> None:
    required = {"data", "profiles", "configuration", "updateJournal"}
    allowed = required | {"scene"}
    allowed_keys(schemas, required, allowed, "schemas")
    for name, value in schemas.items():
        positive_integer(value, f"schemas.{name}")
    if production and "scene" not in schemas:
        raise ManifestValidationError("production manifest has no scene schema")


def validate_external_schemas(schemas: dict, *, production: bool) -> None:
    expected = {"rootData", "profile", "configuration", "scene", "updateJournal"}
    exact_keys(schemas, expected, "schemas")
    for name, value in schemas.items():
        if value is None:
            if production:
                raise ManifestValidationError(f"production manifest has no {name} schema")
            continue
        positive_integer(value, f"schemas.{name}")


def validate_source(source: dict, *, external: bool) -> None:
    expected = {"commit", "tag", "packageResolvedSHA256"}
    if external:
        expected |= {
            "mihomoManifestSHA256",
            "mihomoArchiveSHA256",
            "architectureFreezeSHA256",
        }
    exact_keys(source, expected, "source")
    if re.fullmatch(r"[0-9a-f]{40}", str(source.get("commit", ""))) is None:
        raise ManifestValidationError("manifest commit must be a full lowercase SHA-1")
    nonempty_string(source.get("tag"), "source.tag")
    hash_names = ["packageResolvedSHA256"]
    if external:
        hash_names.extend(
            [
                "mihomoManifestSHA256",
                "mihomoArchiveSHA256",
                "architectureFreezeSHA256",
            ]
        )
    for key in hash_names:
        if re.fullmatch(r"[0-9a-f]{64}", str(source.get(key, ""))) is None:
            raise ManifestValidationError(f"manifest {key} is invalid")


def validate_toolchain(toolchain: dict, *, external: bool) -> None:
    expected = {"xcode", "swift", "sdk", "hostArchitecture"}
    if external:
        expected.add("xcodeBuild")
    exact_keys(toolchain, expected, "toolchain")
    for name in expected:
        nonempty_string(toolchain.get(name), f"toolchain.{name}")
    if toolchain.get("hostArchitecture") != "arm64":
        raise ManifestValidationError("toolchain hostArchitecture must be arm64")


def validate_trust(trust: dict, *, production: bool) -> None:
    expected = {
        "teamIdentifier",
        "sparklePublicKeySHA256",
        "signingCertificateSHA256",
        "signingCertificateSerial",
    }
    exact_keys(trust, expected, "trust")
    if re.fullmatch(r"[A-Z0-9]{10}", str(trust.get("teamIdentifier", ""))) is None:
        raise ManifestValidationError("manifest Team ID is invalid")
    for name in ("sparklePublicKeySHA256", "signingCertificateSHA256"):
        value = trust.get(name)
        if value is not None and re.fullmatch(r"[0-9a-f]{64}", str(value)) is None:
            raise ManifestValidationError(f"trust.{name} is invalid")
        if production and value is None:
            raise ManifestValidationError(f"production external manifest lacks trust.{name}")
    serial = trust.get("signingCertificateSerial")
    if serial is not None and re.fullmatch(r"[0-9a-f]+", str(serial)) is None:
        raise ManifestValidationError("trust.signingCertificateSerial is invalid")
    if production and serial is None:
        raise ManifestValidationError("production external manifest lacks certificate serial")


def validate_external_artifacts(manifest: dict, *, production: bool) -> None:
    artifacts = require_object(manifest, "artifacts")
    notarization = require_object(manifest, "notarization")
    exact_keys(artifacts, {"appZip", "dmg", "appcast"}, "artifacts")
    for name in ("appZip", "dmg", "appcast"):
        artifact = artifacts.get(name)
        if not isinstance(artifact, dict):
            raise ManifestValidationError(f"external manifest is missing {name}")
        exact_keys(artifact, {"filename", "sha256", "size"}, f"artifacts.{name}")
        if Path(str(artifact.get("filename", ""))).name != artifact.get("filename"):
            raise ManifestValidationError(f"{name} filename must be a basename")
        if re.fullmatch(r"[0-9a-f]{64}", str(artifact.get("sha256", ""))) is None:
            raise ManifestValidationError(f"{name} SHA-256 is invalid")
        positive_integer(artifact.get("size"), f"artifacts.{name}.size")
    exact_keys(notarization, {"app", "dmg"}, "notarization")
    for name in ("app", "dmg"):
        receipt = notarization.get(name)
        if receipt is None:
            if production:
                raise ManifestValidationError(f"{name} notarization is missing")
            continue
        if not isinstance(receipt, dict):
            raise ManifestValidationError(f"notarization.{name} must be an object or null")
        exact_keys(receipt, {"submissionID", "status"}, f"notarization.{name}")
        nonempty_string(receipt.get("submissionID"), f"notarization.{name}.submissionID")
        if receipt.get("status") != "Accepted":
            raise ManifestValidationError(f"{name} notarization is not Accepted")
    app_bundle = manifest.get("appBundle")
    if app_bundle is not None:
        if not isinstance(app_bundle, dict):
            raise ManifestValidationError("appBundle must be an object")
        exact_keys(app_bundle, {"name"}, "appBundle")
        if app_bundle.get("name") != "Vela.app":
            raise ManifestValidationError("external manifest App bundle metadata is invalid")


def main() -> int:
    default_root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description="Validate a Vela release manifest")
    parser.add_argument("manifest")
    parser.add_argument("--kind", choices=["bundle", "external"], required=True)
    parser.add_argument("--app-info")
    parser.add_argument("--package-resolved")
    parser.add_argument(
        "--architecture-freeze",
        default=str(default_root / "Hardening/config/architecture-freeze.json"),
        help="approved architecture freeze whose exact bytes external manifests must bind",
    )
    parser.add_argument("--production", action="store_true")
    args = parser.parse_args()

    try:
        manifest = load_json(Path(args.manifest))
        external = args.kind == "external"
        expected = set(EXTERNAL_KEYS if external else BUNDLE_KEYS)
        if external and "appBundle" in manifest:
            expected.add("appBundle")
        exact_keys(manifest, expected, f"{args.kind} manifest")
        if manifest.get("schemaVersion") != 1:
            raise ManifestValidationError("manifest schemaVersion is invalid")
        if external and manifest.get("manifestKind") != "external":
            raise ManifestValidationError("external manifestKind is invalid")

        app = require_object(manifest, "app")
        build = require_object(manifest, "build")
        platform = require_object(manifest, "platform")
        components = require_object(manifest, "components")
        protocols = require_object(manifest, "protocols")
        schemas = require_object(manifest, "schemas")
        source = require_object(manifest, "source")
        toolchain = require_object(manifest, "toolchain")

        validate_app(app, external=external)
        validate_build_object(build, external=external)
        validate_platform(platform)
        validate_components(components, external=external, production=args.production)
        validate_source(source, external=external)
        validate_toolchain(toolchain, external=external)
        if external:
            validate_external_protocols(protocols, production=args.production)
            validate_external_schemas(schemas, production=args.production)
            validate_trust(require_object(manifest, "trust"), production=args.production)
            validate_external_artifacts(manifest, production=args.production)
            architecture_path = Path(args.architecture_freeze)
            if sha256(architecture_path) != source["architectureFreezeSHA256"]:
                raise ManifestValidationError(
                    "architecture freeze hash differs from external manifest"
                )
        else:
            validate_bundle_protocols(protocols, production=args.production)
            validate_bundle_schemas(schemas, production=args.production)

        if args.app_info:
            info_path = Path(args.app_info)
            if not info_path.is_file() or info_path.is_symlink():
                raise ManifestValidationError("--app-info must be a regular plist")
            with info_path.open("rb") as handle:
                info = plistlib.load(handle)
            if info.get("CFBundleIdentifier") != app["bundleIdentifier"]:
                raise ManifestValidationError("manifest bundle identifier differs from Info.plist")
            if info.get("CFBundleShortVersionString") != app["version"]:
                raise ManifestValidationError("manifest version differs from Info.plist")
            if str(info.get("CFBundleVersion")) != str(app["build"]):
                raise ManifestValidationError("manifest build differs from Info.plist")
        if args.package_resolved:
            package_path = Path(args.package_resolved)
            if not package_path.is_file() or package_path.is_symlink():
                raise ManifestValidationError("--package-resolved must be a regular file")
            if sha256(package_path) != source["packageResolvedSHA256"]:
                raise ManifestValidationError("Package.resolved hash differs from manifest")

        if args.production and build.get("sourceDirty") is not False:
            raise ManifestValidationError("production manifest must have sourceDirty=false")

        serialized = json.dumps(manifest, sort_keys=True)
        if re.search(r"/Users/|PRIVATE KEY|Authorization:|keychain", serialized, re.IGNORECASE):
            raise ManifestValidationError("manifest contains forbidden local/secret material")
        print(f"Release manifest validation passed: {args.kind}")
        return 0
    except (
        OSError,
        UnicodeError,
        json.JSONDecodeError,
        plistlib.InvalidFileException,
        ManifestValidationError,
    ) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
