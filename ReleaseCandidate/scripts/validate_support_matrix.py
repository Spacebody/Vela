#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

from _common import GateError, load_json, main_error, reject_forbidden_text, validate_schema


APP_SUPPORT = {
    "currentStable": "full",
    "previousStable": "upgradeAndRecoveryGuidance",
    "betaOrRC": "bestEffort",
}
CORE_SUPPORT = {
    "factory": "supported",
    "signedCatalogCompatible": "supported",
    "blocked": "unsupportedForActivation",
    "arbitraryExternal": "unsupported",
}
UNSUPPORTED = {
    "Intel",
    "UniversalBinary",
    "modifiedHelper",
    "repackagedUnsignedApp",
    "arbitraryCore",
    "manualRootStoreModification",
    "forcedDowngradeOverNewerSchema",
}
CORE_METHODS = {
    "prepareCoreInstall",
    "stageCoreFile",
    "commitCoreInstall",
    "abortCoreInstall",
    "listInstalledCores",
    "refreshCoreCatalog",
    "removeCore",
    "validateCore",
}
CORE_SOURCES = {
    "Vendor/Mihomo/manifest.json",
    "VelaIPC/CoreCatalogTrust.swift",
    "Vela/Core/CoreLifecycle/CoreLifecycleController.swift",
}


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate the frozen V1 support matrix")
    parser.add_argument("manifest")
    parser.add_argument("--public-contract")
    args = parser.parse_args()
    try:
        value = load_json(Path(args.manifest), label="support matrix")
        validate_schema(value, "support-matrix.schema.json")
        reject_forbidden_text(value, label="support matrix")

        app_support = {item["range"]: item["support"] for item in value["appVersions"]}
        if app_support != APP_SUPPORT or len(value["appVersions"]) != len(APP_SUPPORT):
            raise GateError("support matrix must contain the exact V1 app-version policy")
        if value["cores"] != CORE_SUPPORT:
            raise GateError("support matrix must contain the exact V1 Core policy")
        if set(value["unsupported"]) != UNSUPPORTED:
            raise GateError("support matrix unsupported set differs from the frozen V1 policy")

        if args.public_contract:
            contract = load_json(Path(args.public_contract), label="public contract")
            if contract.get("schemaVersion") != 1:
                raise GateError("public contract schemaVersion is not V1")
            if contract.get("app") != value["platform"]:
                raise GateError("support platform differs from the frozen public contract")

            sources = set(contract.get("sources", []))
            missing_sources = CORE_SOURCES - sources
            if missing_sources:
                raise GateError(f"public contract lacks frozen Core sources: {sorted(missing_sources)}")

            helper = contract.get("protocols", {}).get("helper", {})
            methods = set(helper.get("methods", []))
            missing_methods = CORE_METHODS - methods
            if missing_methods:
                raise GateError(f"public contract lacks frozen Core lifecycle methods: {sorted(missing_methods)}")

            roots = [
                root
                for root in contract.get("trustRoots", [])
                if root.get("kind") == "coreCatalogEd25519"
            ]
            if len(roots) != 1:
                raise GateError("public contract must contain exactly one Core catalog trust-root record")
            root = roots[0]
            if root.get("keySetVersion") != 1 or root.get("status") not in {"configured", "unprovisioned"}:
                raise GateError("public contract Core catalog trust-root shape differs from V1")
            if root.get("status") == "unprovisioned" and root.get("identifier") != []:
                raise GateError("unprovisioned Core catalog trust root must not claim key identifiers")

        print("V1 support matrix validation passed.")
        return 0
    except (GateError, OSError, KeyError, TypeError, ValueError) as error:
        return main_error(error)


if __name__ == "__main__":
    raise SystemExit(main())
