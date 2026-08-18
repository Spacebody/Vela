#!/usr/bin/env python3
"""Strictly validate Vela's source-derived V1 public contract."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


TOP_LEVEL = {
    "schemaVersion",
    "generatedBy",
    "app",
    "identifiers",
    "protocols",
    "cli",
    "appIntents",
    "schemas",
    "trustRoots",
    "helpTopics",
    "configuration",
    "userDefaults",
    "keychain",
    "urlSchemes",
    "absentSurfaces",
    "sources",
}
EXPECTED_HELPER_METHODS = [
    "handshake",
    "status",
    "prepareStart",
    "stageConfiguration",
    "stageResource",
    "commitStart",
    "abortStart",
    "stop",
    "renewLease",
    "readLogBatch",
    "cleanup",
    "prepareCoreInstall",
    "stageCoreFile",
    "commitCoreInstall",
    "abortCoreInstall",
    "listInstalledCores",
    "refreshCoreCatalog",
    "removeCore",
    "validateCore",
]
EXPECTED_SCHEMAS = {
    "configurationLayer": 1,
    "coreData": 6,
    "help": 1,
    "onboarding": 1,
    "profile": 2,
    "releaseManifest": 1,
    "rootCoreInstallTransaction": 3,
    "rootCoreStore": 2,
    "rootData": 3,
    "rootStartTransaction": 4,
    "scene": None,
    "supportBundle": 1,
    "updateJournal": 1,
    "userCoreStore": 1,
    "xpcPayload": 1,
}
EXPECTED_HELP_TOPICS = [
    "getting-started",
    "configurations-and-subscriptions",
    "system-proxy-vs-tun",
    "connections-and-routing",
    "scenes-and-automation",
    "configuration-workbench",
    "diagnostics-and-support",
    "troubleshooting-network",
    "app-and-core-updates",
    "cli-and-shortcuts",
    "privacy-and-security",
]
EXPECTED_CONFIGURATION = {
    "layerKinds": [
        "global",
        "profile",
        "scene",
        "runtimeForced",
        "privilegedSanitizer",
    ],
    "operationKinds": [
        "set",
        "remove",
        "deepMerge",
        "prependUnique",
        "appendUnique",
        "upsertNamed",
        "removeNamed",
    ],
    "duplicatePolicies": ["replace", "deepMerge", "error"],
    "insertionPositions": ["beginning", "end"],
}
EXPECTED_DEFAULTS = {
    "VelaUpdateChannel": "ReleaseChannel.rawValue",
    "dev.yilin.Vela.CoreCatalog.lastAutomaticCheckAttempt": "Date",
    "dev.yilin.Vela.PublicBeta.localEvidenceEnabled": "Bool",
    "dev.yilin.Vela.PublicBeta.safeModeOnNextLaunch": "Bool",
    "privilegedTun.preferences.v1": "TunPreferences",
}
EXPECTED_ABSENT = [
    "productionAppIntents",
    "productionAutomationSocket",
    "productionCLI",
    "productionSceneStore",
]
PLACEHOLDERS = ("REPLACE_WITH", "__PIN", "__SUPPORT", "TODO", "TBD")
SECRET_MARKERS = (
    "BEGIN PRIVATE KEY",
    "BEGIN RSA PRIVATE KEY",
    "Authorization: Bearer",
    "password=",
    "token=",
)


class ContractError(ValueError):
    pass


def load(path: Path) -> dict:
    if not path.is_file() or path.is_symlink():
        raise ContractError(f"expected a regular contract file: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ContractError(f"cannot read {path}: {error}") from error
    if not isinstance(value, dict):
        raise ContractError("public contract must be a JSON object")
    return value


def exact_keys(value: object, expected: set[str], label: str) -> dict:
    if not isinstance(value, dict):
        raise ContractError(f"{label} must be an object")
    if set(value) != expected:
        raise ContractError(
            f"{label} keys differ; missing={sorted(expected - set(value))}, "
            f"extra={sorted(set(value) - expected)}"
        )
    return value


def unique_strings(value: object, label: str, *, allow_empty: bool = False) -> list[str]:
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        raise ContractError(f"{label} must be an array of strings")
    if not allow_empty and not value:
        raise ContractError(f"{label} must not be empty")
    if len(value) != len(set(value)):
        raise ContractError(f"{label} contains duplicate values")
    return value


def validate_absent_machine_surfaces(value: dict) -> None:
    cli = exact_keys(
        value.get("cli"),
        {
            "availability",
            "bundleIdentifier",
            "protocol",
            "schemaVersions",
            "commands",
            "options",
            "exitCodes",
            "errorCodes",
            "environmentVariables",
        },
        "cli",
    )
    if cli != {
        "availability": "absent",
        "bundleIdentifier": None,
        "protocol": None,
        "schemaVersions": [],
        "commands": [],
        "options": [],
        "exitCodes": {},
        "errorCodes": {},
        "environmentVariables": [],
    }:
        raise ContractError("CLI must remain explicitly absent in the V1 baseline")

    intents = exact_keys(
        value.get("appIntents"),
        {
            "availability",
            "intentTypeNames",
            "entityTypes",
            "enumTypes",
            "shortcutIdentifiers",
        },
        "appIntents",
    )
    if intents != {
        "availability": "absent",
        "intentTypeNames": [],
        "entityTypes": [],
        "enumTypes": [],
        "shortcutIdentifiers": [],
    }:
        raise ContractError("App Intents must remain explicitly absent in the V1 baseline")


def validate_helper(value: object) -> None:
    protocols = exact_keys(value, {"helper", "automation"}, "protocols")
    if protocols.get("automation") is not None:
        raise ContractError("Automation protocol must remain absent in the V1 baseline")
    helper = exact_keys(
        protocols.get("helper"),
        {
            "minimum",
            "maximum",
            "methodCount",
            "methods",
            "errorDomain",
            "errorCodes",
        },
        "protocols.helper",
    )
    if helper.get("minimum") != 2 or helper.get("maximum") != 2:
        raise ContractError("Helper protocol range must remain 2...2")
    if helper.get("methods") != EXPECTED_HELPER_METHODS:
        raise ContractError(
            "Helper method registry changed; the real V1 baseline has 19 methods "
            "including refreshCoreCatalog"
        )
    if helper.get("methodCount") != len(EXPECTED_HELPER_METHODS):
        raise ContractError("Helper methodCount must be 19")
    if helper.get("errorDomain") != "dev.yilin.Vela.HelperError":
        raise ContractError("Helper error domain changed")
    errors = helper.get("errorCodes")
    if not isinstance(errors, list) or not errors:
        raise ContractError("Helper errorCodes must be a non-empty array")
    names: list[str] = []
    codes: list[int] = []
    for item in errors:
        entry = exact_keys(item, {"name", "value"}, "Helper error code")
        if not isinstance(entry.get("name"), str) or not entry["name"]:
            raise ContractError("Helper error code name is invalid")
        if not isinstance(entry.get("value"), int) or entry["value"] <= 0:
            raise ContractError("Helper error code value is invalid")
        names.append(entry["name"])
        codes.append(entry["value"])
    if len(names) != len(set(names)) or len(codes) != len(set(codes)):
        raise ContractError("Helper error codes contain duplicates")


def validate_trust_roots(value: object) -> None:
    if not isinstance(value, list) or len(value) != 3:
        raise ContractError("trustRoots must contain the three frozen categories")
    roots = {
        item.get("kind"): item
        for item in value
        if isinstance(item, dict) and isinstance(item.get("kind"), str)
    }
    if set(roots) != {"developerIDTeam", "sparkleEdDSA", "coreCatalogEd25519"}:
        raise ContractError("trust-root categories changed")
    developer = roots["developerIDTeam"]
    if developer != {
        "kind": "developerIDTeam",
        "identifier": "2E56T94S33",
        "status": "configured",
    }:
        raise ContractError("Developer ID Team trust root changed")
    sparkle = roots["sparkleEdDSA"]
    if set(sparkle) != {"kind", "identifier", "status"}:
        raise ContractError("Sparkle trust-root shape changed")
    sparkle_id = sparkle.get("identifier")
    expected_sparkle_status = "configured" if isinstance(sparkle_id, str) else "unprovisioned"
    if sparkle.get("status") != expected_sparkle_status:
        raise ContractError("Sparkle trust-root provisioning status is inconsistent")
    core = roots["coreCatalogEd25519"]
    if set(core) != {"kind", "identifier", "keySetVersion", "status"}:
        raise ContractError("Core Catalog trust-root shape changed")
    core_ids = core.get("identifier")
    if (
        not isinstance(core_ids, list)
        or any(not isinstance(item, str) or not item for item in core_ids)
        or len(core_ids) != len(set(core_ids))
    ):
        raise ContractError("Core Catalog key identifiers are invalid")
    if core.get("keySetVersion") != 1:
        raise ContractError("Core Catalog key-set version changed")
    expected_core_status = "configured" if core_ids else "unprovisioned"
    if core.get("status") != expected_core_status:
        raise ContractError("Core Catalog trust-root provisioning status is inconsistent")


def validate_defaults(value: object) -> None:
    if not isinstance(value, list) or len(value) != len(EXPECTED_DEFAULTS):
        raise ContractError("migration-relevant UserDefaults inventory is incomplete")
    actual: dict[str, str] = {}
    for item in value:
        entry = exact_keys(item, {"key", "valueSchema", "source"}, "UserDefaults entry")
        key = entry.get("key")
        schema = entry.get("valueSchema")
        source = entry.get("source")
        if not all(isinstance(part, str) and part for part in (key, schema, source)):
            raise ContractError("UserDefaults entry contains an invalid field")
        if key in actual:
            raise ContractError("UserDefaults inventory contains a duplicate key")
        actual[key] = schema
    if actual != EXPECTED_DEFAULTS:
        raise ContractError("migration-relevant UserDefaults keys or schemas changed")


def validate(value: dict) -> None:
    if set(value) != TOP_LEVEL:
        raise ContractError(
            f"public contract keys differ; missing={sorted(TOP_LEVEL - set(value))}, "
            f"extra={sorted(set(value) - TOP_LEVEL)}"
        )
    if value.get("schemaVersion") != 1:
        raise ContractError("public contract schemaVersion must be 1")
    generated = exact_keys(value.get("generatedBy"), {"name", "version"}, "generatedBy")
    if generated != {"name": "generate_project_contracts.py", "version": 1}:
        raise ContractError("public contract generator identity changed")
    app = exact_keys(value.get("app"), {"minimumMacOS", "architectures"}, "app")
    if app != {"minimumMacOS": "15.0", "architectures": ["arm64"]}:
        raise ContractError("V1 platform support contract changed")
    identifiers = exact_keys(
        value.get("identifiers"),
        {"app", "helper", "helperMachService", "cli", "appGroup"},
        "identifiers",
    )
    if identifiers != {
        "app": "dev.yilin.Vela",
        "helper": "dev.yilin.Vela.Helper",
        "helperMachService": "dev.yilin.Vela.Helper",
        "cli": None,
        "appGroup": None,
    }:
        raise ContractError("bundle or system-integration identifiers changed")

    validate_helper(value.get("protocols"))
    validate_absent_machine_surfaces(value)
    if value.get("schemas") != EXPECTED_SCHEMAS:
        raise ContractError("persisted or public schema registry changed")
    validate_trust_roots(value.get("trustRoots"))
    if value.get("helpTopics") != EXPECTED_HELP_TOPICS:
        raise ContractError("Help Topic ID registry changed")
    if value.get("configuration") != EXPECTED_CONFIGURATION:
        raise ContractError("configuration layer/operation raw-value registry changed")
    validate_defaults(value.get("userDefaults"))

    keychain = value.get("keychain")
    if keychain != [
        {
            "accountTemplate": "<profile-uuid>",
            "service": "dev.yilin.Vela.subscription",
            "valueCategory": "subscription URL and authentication envelope",
        }
    ]:
        raise ContractError("Keychain service/category contract changed")
    if value.get("urlSchemes") != []:
        raise ContractError("V1 baseline must not advertise a URL scheme")
    if value.get("absentSurfaces") != EXPECTED_ABSENT:
        raise ContractError("frozen absent public surfaces changed")
    sources = unique_strings(value.get("sources"), "sources")
    if sources != sorted(sources):
        raise ContractError("source inventory must be sorted deterministically")
    if any(path.startswith("Docs/") or "/Tests/" in path for path in sources):
        raise ContractError("contract extraction must not use pack/test fixtures as product truth")

    serialized = json.dumps(value, ensure_ascii=False)
    if any(marker in serialized for marker in PLACEHOLDERS):
        raise ContractError("public contract contains a placeholder")
    if any(marker.lower() in serialized.lower() for marker in SECRET_MARKERS):
        raise ContractError("public contract contains secret-shaped material")


def validate_registry_cross_reference(contract: dict, registry_path: Path) -> None:
    registry = load(registry_path)
    expected = {
        "schemaVersion": 1,
        "availability": contract["appIntents"]["availability"],
        "intents": contract["appIntents"]["intentTypeNames"],
        "entities": contract["appIntents"]["entityTypes"],
        "enums": contract["appIntents"]["enumTypes"],
        "shortcuts": contract["appIntents"]["shortcutIdentifiers"],
    }
    if registry != expected:
        raise ContractError("App Intent registry disagrees with public contract")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest")
    parser.add_argument("--app-intent-registry")
    args = parser.parse_args()
    try:
        contract = load(Path(args.manifest))
        validate(contract)
        if args.app_intent_registry:
            validate_registry_cross_reference(
                contract,
                Path(args.app_intent_registry),
            )
    except ContractError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print("Public Contract Freeze validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
