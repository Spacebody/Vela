#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse


EXPECTED_TOP_LEVEL = {
    "schemaVersion",
    "product",
    "toolchain",
    "versioning",
    "updates",
    "paths",
    "releaseRequirements",
}


class ValidationError(ValueError):
    pass


def load_json(path: Path) -> dict:
    if not path.is_file() or path.is_symlink():
        raise ValidationError(f"expected a regular JSON file: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValidationError(f"could not read {path}: {error}") from error
    if not isinstance(value, dict):
        raise ValidationError(f"expected a JSON object: {path}")
    return value


def require_mapping(parent: dict, key: str) -> dict:
    value = parent.get(key)
    if not isinstance(value, dict):
        raise ValidationError(f"{key} must be an object")
    return value


def require_string(parent: dict, key: str) -> str:
    value = parent.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValidationError(f"{key} must be a non-empty string")
    return value


def safe_repo_path(root: Path, raw: str, *, must_exist: bool = True) -> Path:
    candidate = Path(raw)
    if candidate.is_absolute() or ".." in candidate.parts:
        raise ValidationError(f"repository path must be relative and contained: {raw}")
    resolved = (root / candidate).resolve()
    try:
        resolved.relative_to(root.resolve())
    except ValueError as error:
        raise ValidationError(f"repository path escapes the checkout: {raw}") from error
    if must_exist and not resolved.exists():
        raise ValidationError(f"configured path does not exist: {raw}")
    return resolved


def git_tracked(root: Path, relative: str) -> bool:
    result = subprocess.run(
        ["git", "-C", str(root), "ls-files", "--error-unmatch", relative],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode == 0


def command_output(*args: str) -> str:
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()


def package_pin(resolved: dict, identity: str) -> dict | None:
    pins = resolved.get("pins")
    if not isinstance(pins, list):
        raise ValidationError("Package.resolved pins must be an array")
    for pin in pins:
        if isinstance(pin, dict) and str(pin.get("identity", "")).lower() == identity:
            return pin
    return None


def app_intent_release_blockers(root: Path, *, required: bool) -> list[str]:
    contract = load_json(
        safe_repo_path(root, "Contracts/v1/public-contract-freeze.json")
    )
    absent_surfaces = contract.get("absentSurfaces")
    if (
        not isinstance(absent_surfaces, list)
        or any(not isinstance(item, str) or not item for item in absent_surfaces)
        or len(absent_surfaces) != len(set(absent_surfaces))
    ):
        raise ValidationError(
            "public contract absentSurfaces must be an array of unique non-empty strings"
        )
    app_intents = require_mapping(contract, "appIntents")
    availability = app_intents.get("availability")
    if availability not in {"absent", "available"}:
        raise ValidationError(
            "public contract appIntents.availability must be absent or available"
        )
    has_absent_marker = "productionAppIntents" in absent_surfaces
    if has_absent_marker != (availability == "absent"):
        raise ValidationError(
            "public contract productionAppIntents marker differs from "
            "appIntents.availability"
        )
    if required and availability != "available":
        return ["App Intents are absent from the V1 public contract freeze"]
    return []


def validate(config_path: Path, root: Path, check_toolchain: bool) -> list[str]:
    blockers: list[str] = []
    config = load_json(config_path)
    if set(config) != EXPECTED_TOP_LEVEL:
        missing = sorted(EXPECTED_TOP_LEVEL - set(config))
        extra = sorted(set(config) - EXPECTED_TOP_LEVEL)
        raise ValidationError(f"release config keys differ; missing={missing}, extra={extra}")
    if config.get("schemaVersion") != 1:
        raise ValidationError("release config schemaVersion must be 1")

    product = require_mapping(config, "product")
    expected_product_values = {
        "name": "Vela",
        "project": "Vela.xcodeproj",
        "scheme": "Vela",
        "bundleIdentifier": "dev.yilin.Vela",
        "helperIdentifier": "dev.yilin.Vela.Helper",
        "cliName": "vela",
        "minimumMacOS": "15.0",
        "architecture": "arm64",
        "mihomoVersion": "v1.19.29",
        "sparkleVersion": "2.9.4",
        "yamsVersion": "6.2.2",
    }
    for key, expected in expected_product_values.items():
        actual = require_string(product, key)
        if actual != expected:
            raise ValidationError(f"product.{key} must be {expected!r}, got {actual!r}")
    team = require_string(product, "teamIdentifier")
    if re.fullmatch(r"[A-Z0-9]{10}", team) is None:
        raise ValidationError("product.teamIdentifier must be a 10-character Team ID")
    safe_repo_path(root, product["project"])

    versioning = require_mapping(config, "versioning")
    if re.fullmatch(r"\d+\.\d+\.\d+", require_string(versioning, "marketingVersion")) is None:
        raise ValidationError("versioning.marketingVersion must be major.minor.patch")
    if versioning.get("buildNumberStrategy") != "YYYYMMDDNN":
        raise ValidationError("versioning.buildNumberStrategy must be YYYYMMDDNN")

    updates = require_mapping(config, "updates")
    feed = require_string(updates, "feedURL")
    parsed_feed = urlparse(feed)
    if (
        parsed_feed.scheme != "https"
        or not parsed_feed.hostname
        or parsed_feed.username is not None
        or parsed_feed.password is not None
        or parsed_feed.query
        or parsed_feed.fragment
    ):
        raise ValidationError("updates.feedURL must be a fixed HTTPS URL without credentials/query/fragment")
    if "__" in feed or parsed_feed.hostname.endswith(".invalid"):
        blockers.append("updates.feedURL is a non-production placeholder")

    public_key = require_string(updates, "publicEDKey")
    if "__" in public_key:
        blockers.append("updates.publicEDKey is a placeholder")
    else:
        try:
            decoded_key = base64.b64decode(public_key, validate=True)
        except ValueError as error:
            raise ValidationError("updates.publicEDKey must be valid base64") from error
        if len(decoded_key) != 32:
            raise ValidationError("updates.publicEDKey must decode to a 32-byte Ed25519 public key")
    if updates.get("channels") != ["stable", "beta"]:
        raise ValidationError("updates.channels must be ['stable', 'beta']")
    if updates.get("allowedURLSchemes") != ["https"]:
        raise ValidationError("updates.allowedURLSchemes must contain only https")
    expected_update_flags = {
        "requireSignedFeed": True,
        "verifyBeforeExtraction": True,
        "enableJavaScript": False,
        "enableSystemProfiling": False,
        "deltasEnabled": False,
    }
    for key, expected in expected_update_flags.items():
        if updates.get(key) is not expected:
            raise ValidationError(f"updates.{key} must be {expected}")

    paths = require_mapping(config, "paths")
    resolved_paths: dict[str, Path] = {}
    for key in [
        "packageResolved",
        "mihomoManifest",
        "compatibility",
        "appcastPolicy",
        "thirdPartyComponents",
        "exportOptions",
    ]:
        resolved_paths[key] = safe_repo_path(root, require_string(paths, key))
    for key in ["staging", "output"]:
        safe_repo_path(root, require_string(paths, key), must_exist=False)

    compatibility = load_json(resolved_paths["compatibility"])
    if compatibility.get("schemaVersion") != 1:
        raise ValidationError("compatibility schemaVersion must be 1")
    helper_protocol = require_mapping(compatibility, "helperProtocol")
    helper_minimum = helper_protocol.get("minimum")
    helper_maximum = helper_protocol.get("maximum")
    if not isinstance(helper_minimum, int) or not isinstance(helper_maximum, int):
        raise ValidationError("helper protocol bounds must be integers")
    if helper_minimum < 1 or helper_maximum < helper_minimum:
        raise ValidationError("helper protocol bounds are invalid")

    requirements = require_mapping(config, "releaseRequirements")
    if requirements.get("requiredComponents") != [
        "Vela",
        "VelaHelper",
        "mihomo",
        "vela",
        "Sparkle.framework",
    ]:
        raise ValidationError("releaseRequirements.requiredComponents drifted")
    for key in [
        "requireCLI",
        "requireAppIntents",
        "requireAutomationProtocol",
        "requireSceneSchema",
        "requireSignedReleaseNotes",
        "requireSignedAppcast",
    ]:
        if requirements.get(key) is not True:
            raise ValidationError(f"releaseRequirements.{key} must be true")
    blockers.extend(
        app_intent_release_blockers(
            root,
            required=requirements["requireAppIntents"],
        )
    )
    if requirements.get("requireCLI") is True and compatibility.get("cliProtocol") is None:
        blockers.append("CLI protocol is not implemented in compatibility.json")
    if requirements.get("requireAutomationProtocol") is True and compatibility.get("automationProtocol") is None:
        blockers.append("Automation protocol is not implemented in compatibility.json")
    schemas = require_mapping(compatibility, "schemas")
    if requirements.get("requireSceneSchema") is True and schemas.get("scene") is None:
        blockers.append("Scene schema is not implemented in compatibility.json")
    components = require_mapping(compatibility, "components")
    if components.get("cli") is None:
        blockers.append("CLI component version is not implemented in compatibility.json")
    if components.get("mihomo") != product["mihomoVersion"]:
        raise ValidationError("compatibility Mihomo version differs from release config")
    if components.get("sparkle") != product["sparkleVersion"]:
        raise ValidationError("compatibility Sparkle version differs from release config")

    appcast_policy = load_json(resolved_paths["appcastPolicy"])
    expected_policy = {
        "schemaVersion": 1,
        "minimumMacOS": "15.0.0",
        "hardware": "arm64",
        "channels": ["stable", "beta"],
        "deltasEnabled": False,
        "signedFeedRequired": True,
        "signedReleaseNotesRequired": True,
        "httpsOnly": True,
        "trackingQueryAllowed": False,
        "stableMustSupersedeBeta": True,
    }
    for key, expected in expected_policy.items():
        if appcast_policy.get(key) != expected:
            raise ValidationError(f"appcast policy {key} must be {expected!r}")

    with resolved_paths["exportOptions"].open("rb") as handle:
        export_options = plistlib.load(handle)
    if export_options.get("method") != "developer-id":
        raise ValidationError("ExportOptions method must be developer-id")
    if export_options.get("teamID") != team:
        raise ValidationError("ExportOptions teamID differs from release config")

    third_party = load_json(resolved_paths["thirdPartyComponents"])
    if third_party.get("schemaVersion") != 1:
        raise ValidationError("third-party component schemaVersion must be 1")
    entries = third_party.get("components")
    if not isinstance(entries, list) or not entries:
        raise ValidationError("third-party components must be a non-empty array")
    names: set[str] = set()
    for entry in entries:
        if not isinstance(entry, dict):
            raise ValidationError("third-party component entry must be an object")
        name = require_string(entry, "name")
        if name in names:
            raise ValidationError(f"duplicate third-party component: {name}")
        names.add(name)
        require_string(entry, "version")
        license_expression = require_string(entry, "licenseDeclared")
        if license_expression == "NOASSERTION":
            blockers.append(f"{name} license is NOASSERTION")
        license_path = safe_repo_path(root, require_string(entry, "licenseFile"))
        if license_path.stat().st_size == 0:
            raise ValidationError(f"third-party license is empty: {license_path}")
        location = urlparse(require_string(entry, "downloadLocation"))
        if location.scheme != "https" or not location.hostname:
            raise ValidationError(f"{name} downloadLocation must be HTTPS")
    for required_name in ["Sparkle", "Yams", "Mihomo"]:
        if required_name not in names:
            raise ValidationError(f"missing third-party component: {required_name}")

    resolved = load_json(resolved_paths["packageResolved"])
    for identity, version in [("sparkle", "2.9.4"), ("yams", "6.2.2")]:
        pin = package_pin(resolved, identity)
        if pin is None:
            blockers.append(f"Package.resolved does not contain {identity} {version}")
            continue
        state = pin.get("state")
        if not isinstance(state, dict) or state.get("version") != version:
            blockers.append(f"Package.resolved does not pin {identity} exactly to {version}")

    package_relative = str(resolved_paths["packageResolved"].relative_to(root.resolve()))
    if not git_tracked(root, package_relative):
        blockers.append(f"Package.resolved is not tracked: {package_relative}")

    project_text = (root / product["project"] / "project.pbxproj").read_text(encoding="utf-8")
    if "https://github.com/sparkle-project/Sparkle" not in project_text:
        blockers.append("Vela.xcodeproj does not reference Sparkle")
    elif re.search(r"kind\s*=\s*exactVersion;\s*version\s*=\s*2\.9\.4;", project_text) is None:
        blockers.append("Vela.xcodeproj does not require Sparkle exact 2.9.4")
    yams_block = re.search(
        r'XCRemoteSwiftPackageReference "Yams".*?requirement\s*=\s*\{(.*?)\};',
        project_text,
        re.DOTALL,
    )
    if yams_block is None or "kind = exactVersion;" not in yams_block.group(1) or "version = 6.2.2;" not in yams_block.group(1):
        blockers.append("Vela.xcodeproj does not require Yams exact 6.2.2")

    if check_toolchain:
        toolchain = require_mapping(config, "toolchain")
        xcode_lines = command_output("xcodebuild", "-version").splitlines()
        if len(xcode_lines) < 2:
            raise ValidationError("xcodebuild -version returned an unexpected result")
        actual_version = xcode_lines[0].removeprefix("Xcode ").strip()
        actual_build = xcode_lines[1].removeprefix("Build version ").strip()
        if actual_version != require_string(toolchain, "xcodeVersion"):
            blockers.append(f"Xcode version is {actual_version}, expected {toolchain['xcodeVersion']}")
        if actual_build != require_string(toolchain, "xcodeBuild"):
            blockers.append(f"Xcode build is {actual_build}, expected {toolchain['xcodeBuild']}")
        if command_output("uname", "-m") != "arm64":
            blockers.append("release host is not arm64")

    return blockers


def main() -> int:
    default_root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description="Validate Vela release configuration")
    parser.add_argument("--config", default="Release/config/release.json")
    parser.add_argument("--repository-root", default=str(default_root))
    parser.add_argument("--production", action="store_true")
    parser.add_argument("--skip-toolchain", action="store_true")
    args = parser.parse_args()

    root = Path(args.repository_root).resolve()
    config_path = Path(args.config)
    if not config_path.is_absolute():
        config_path = root / config_path
    try:
        blockers = validate(config_path, root, not args.skip_toolchain)
    except (ValidationError, OSError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    mode = "production" if args.production else "dry-run"
    print(f"Release configuration structure passed ({mode}).")
    if blockers:
        for blocker in blockers:
            print(f"BLOCKER: {blocker}")
        if args.production:
            print(f"error: {len(blockers)} production blocker(s) remain", file=sys.stderr)
            return 1
        print(f"Dry-run completed with {len(blockers)} expected production blocker(s).")
    else:
        print("No production configuration blockers were found.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
