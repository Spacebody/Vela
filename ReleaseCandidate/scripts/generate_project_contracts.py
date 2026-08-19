#!/usr/bin/env python3
"""Generate Vela's V1 public contracts from the current production sources.

The V0.9 pack fixtures are examples, not product truth.  This generator starts
with the existing Hardening architecture extractor and adds the public values
that are not part of the security architecture manifest.  Missing production
surfaces stay explicitly absent; this script never invents CLI, Automation, or
App Intent identifiers.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import re
import sys
from pathlib import Path
from types import ModuleType
from typing import Any


GENERATOR_NAME = "generate_project_contracts.py"
GENERATOR_VERSION = 1
PUBLIC_CONTRACT_NAME = "public-contract-freeze.json"
APP_INTENT_REGISTRY_NAME = "app-intent-registry.json"
HASHES_NAME = "hashes.json"


class ContractGenerationError(RuntimeError):
    pass


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as error:
        raise ContractGenerationError(f"cannot read {path}: {error}") from error


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(read_text(path))
    except json.JSONDecodeError as error:
        raise ContractGenerationError(f"invalid JSON in {path}: {error}") from error
    if not isinstance(value, dict):
        raise ContractGenerationError(f"expected a JSON object in {path}")
    return value


def canonical_bytes(value: object) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def pretty_bytes(value: object) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")


def canonical_sha256(value: object) -> str:
    return hashlib.sha256(canonical_bytes(value)).hexdigest()


def load_architecture_generator(repo: Path) -> ModuleType:
    path = repo / "Hardening/scripts/generate_architecture_manifest.py"
    spec = importlib.util.spec_from_file_location(
        "vela_hardening_architecture_generator",
        path,
    )
    if spec is None or spec.loader is None:
        raise ContractGenerationError(f"cannot load architecture generator: {path}")
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    except Exception as error:  # noqa: BLE001 - converted to stable generator error
        raise ContractGenerationError(
            f"architecture generator could not be loaded: {error}"
        ) from error
    return module


def architecture_manifest(repo: Path) -> dict[str, Any]:
    module = load_architecture_generator(repo)
    try:
        architecture, _ = module.build(repo)
    except Exception as error:  # noqa: BLE001 - preserve fail-closed behavior
        raise ContractGenerationError(
            f"architecture extraction failed: {error}"
        ) from error
    if not isinstance(architecture, dict):
        raise ContractGenerationError("architecture generator returned an invalid manifest")
    return architecture


def swift_string_constant(source: str, name: str, label: str) -> str:
    matches = re.findall(rf"\b{re.escape(name)}\s*=\s*\"([^\"]+)\"", source, re.S)
    unique = sorted(set(matches))
    if len(unique) != 1:
        raise ContractGenerationError(
            f"expected one {label} string constant, found {unique!r}"
        )
    return unique[0]


def swift_default_string_argument(
    source: str,
    argument: str,
    label: str,
) -> str:
    matches = re.findall(
        rf"\b{re.escape(argument)}\s*:\s*String\s*=\s*\"([^\"]+)\"",
        source,
        re.S,
    )
    unique = sorted(set(matches))
    if len(unique) != 1:
        raise ContractGenerationError(
            f"expected one {label} default string argument, found {unique!r}"
        )
    return unique[0]


def swift_enum_string_values(source: str, enum_name: str) -> list[str]:
    declaration = re.search(
        rf"\b(?:public\s+)?enum\s+{re.escape(enum_name)}\b[^{{]*\{{",
        source,
    )
    if declaration is None:
        raise ContractGenerationError(f"could not find enum {enum_name}")
    following = source[declaration.end() :]
    next_declaration = re.search(
        r"\n(?:nonisolated\s+)?(?:public\s+)?(?:enum|struct|class|actor|protocol)\s+",
        following,
    )
    body = following[: next_declaration.start()] if next_declaration else following
    cases: list[str] = []
    for name, raw in re.findall(
        r"^\s*case\s+([A-Za-z][A-Za-z0-9_]*)(?:\s*=\s*\"([^\"]+)\")?\s*$",
        body,
        re.M,
    ):
        cases.append(raw or name)
    if not cases or len(cases) != len(set(cases)):
        raise ContractGenerationError(f"enum {enum_name} is empty or duplicated")
    return cases


def helper_error_codes(source: str) -> list[dict[str, int | str]]:
    match = re.search(
        r"public\s+enum\s+VelaHelperErrorCode\s*:[^{]+\{(.*?)\n\}",
        source,
        re.S,
    )
    if match is None:
        raise ContractGenerationError("could not extract VelaHelperErrorCode")
    results = [
        {"name": name, "value": int(value.replace("_", ""))}
        for name, value in re.findall(
            r"^\s*case\s+([A-Za-z][A-Za-z0-9_]*)\s*=\s*([0-9_]+)\s*$",
            match.group(1),
            re.M,
        )
    ]
    names = [item["name"] for item in results]
    values = [item["value"] for item in results]
    if not results or len(names) != len(set(names)) or len(values) != len(set(values)):
        raise ContractGenerationError("Helper error codes are empty or duplicated")
    return results


def help_topic_ids(repo: Path) -> list[str]:
    index = read_json(repo / "Vela/Resources/Help/help-index.json")
    articles = index.get("articles")
    if not isinstance(articles, list) or not articles:
        raise ContractGenerationError("Help index has no articles")
    values: list[str] = []
    for article in articles:
        if not isinstance(article, dict) or not isinstance(article.get("id"), str):
            raise ContractGenerationError("Help index contains an invalid article")
        locales = article.get("locales")
        if not isinstance(locales, dict) or set(locales) != {"en", "zh-Hans"}:
            raise ContractGenerationError(
                f"Help topic {article['id']} does not have exact en/zh-Hans parity"
            )
        values.append(article["id"])
    if len(values) != len(set(values)):
        raise ContractGenerationError("Help topic identifiers are duplicated")
    return values


def user_defaults_contract(repo: Path) -> list[dict[str, str]]:
    tun_path = repo / "Vela/Core/Privileged/TunPreferences.swift"
    update_path = repo / "Vela/Core/Updates/UpdateController.swift"
    core_path = repo / "Vela/Core/CoreLifecycle/CoreLifecycleController.swift"
    evidence_path = repo / "Vela/Core/Hardening/PublicBetaEvidenceController.swift"
    safe_mode_path = repo / "Vela/Core/Hardening/PublicBetaSafeMode.swift"
    records = [
        {
            "key": swift_default_string_argument(
                read_text(tun_path), "key", "TUN preference key"
            ),
            "valueSchema": "TunPreferences",
            "source": str(tun_path.relative_to(repo)),
        },
        {
            "key": swift_string_constant(
                read_text(update_path),
                "channelPreferenceKey",
                "update channel preference key",
            ),
            "valueSchema": "ReleaseChannel.rawValue",
            "source": str(update_path.relative_to(repo)),
        },
        {
            "key": swift_string_constant(
                read_text(core_path),
                "lastAutomaticCheckAttemptKey",
                "Core Catalog automatic-check key",
            ),
            "valueSchema": "Date",
            "source": str(core_path.relative_to(repo)),
        },
        {
            "key": swift_string_constant(
                read_text(evidence_path),
                "recordingDefaultsKey",
                "local reliability evidence key",
            ),
            "valueSchema": "Bool",
            "source": str(evidence_path.relative_to(repo)),
        },
        {
            "key": swift_string_constant(
                read_text(safe_mode_path),
                "requestedDefaultsKey",
                "Safe Mode request key",
            ),
            "valueSchema": "Bool",
            "source": str(safe_mode_path.relative_to(repo)),
        },
    ]
    records.sort(key=lambda item: item["key"])
    keys = [item["key"] for item in records]
    if len(keys) != len(set(keys)):
        raise ContractGenerationError("migration-relevant UserDefaults keys are duplicated")
    return records


def configuration_contract(repo: Path) -> dict[str, list[str]]:
    source = read_text(
        repo / "Vela/Core/ConfigurationWorkbench/ConfigurationModels.swift"
    )
    return {
        "layerKinds": swift_enum_string_values(source, "ConfigurationLayerKind"),
        "operationKinds": swift_enum_string_values(
            source, "ConfigurationOperationKind"
        ),
        "duplicatePolicies": swift_enum_string_values(
            source, "ConfigurationDuplicatePolicy"
        ),
        "insertionPositions": swift_enum_string_values(
            source, "ConfigurationInsertionPosition"
        ),
    }


def app_intent_registry(architecture: dict[str, Any]) -> dict[str, Any]:
    identifiers = architecture.get("identifiers", {})
    protocols = architecture.get("protocols", {})
    absent = set(architecture.get("absentSurfaces", []))
    if identifiers.get("appIntentIdentifiers") != []:
        raise ContractGenerationError(
            "architecture manifest declares App Intent identifiers unexpectedly"
        )
    if "productionAppIntents" not in absent:
        raise ContractGenerationError(
            "production App Intents are no longer explicitly absent; update the extractor first"
        )
    if protocols.get("automation") is not None:
        raise ContractGenerationError(
            "App Intent registry cannot remain absent when Automation is declared"
        )
    return {
        "schemaVersion": 1,
        "availability": "absent",
        "intents": [],
        "entities": [],
        "enums": [],
        "shortcuts": [],
    }


def public_contract(repo: Path, architecture: dict[str, Any]) -> dict[str, Any]:
    identifiers = architecture.get("identifiers")
    protocols = architecture.get("protocols")
    product = architecture.get("product")
    if not isinstance(identifiers, dict) or not isinstance(protocols, dict):
        raise ContractGenerationError("architecture identifiers/protocols are missing")
    if not isinstance(product, dict):
        raise ContractGenerationError("architecture product section is missing")
    absent = architecture.get("absentSurfaces")
    required_absent = {
        "productionCLI",
        "productionAutomationSocket",
        "productionAppIntents",
    }
    if not isinstance(absent, list) or not required_absent.issubset(set(absent)):
        raise ContractGenerationError(
            "the current architecture no longer has the expected frozen absent surfaces"
        )
    if identifiers.get("cli") is not None:
        raise ContractGenerationError("CLI identifier exists but no CLI extractor is defined")
    if protocols.get("cli") is not None or protocols.get("automation") is not None:
        raise ContractGenerationError(
            "CLI/Automation protocol exists but the V1 absent-surface contract is still selected"
        )

    helper = protocols.get("helper")
    if not isinstance(helper, dict):
        raise ContractGenerationError("Helper protocol is missing")
    helper_methods = helper.get("methods")
    if not isinstance(helper_methods, list) or helper.get("methodCount") != len(helper_methods):
        raise ContractGenerationError("Helper method count disagrees with extracted methods")

    helper_errors_path = repo / "VelaIPC/VelaHelperError.swift"
    helper_error_source = read_text(helper_errors_path)
    helper_contract = {
        "minimum": helper.get("minimum"),
        "maximum": helper.get("maximum"),
        "methodCount": helper.get("methodCount"),
        "methods": helper_methods,
        "errorDomain": swift_string_constant(
            helper_error_source,
            "VelaHelperErrorDomain",
            "Helper error domain",
        ),
        "errorCodes": helper_error_codes(helper_error_source),
    }

    trust_roots = architecture.get("trustRoots")
    keychain = architecture.get("keychainCategories")
    schemas = architecture.get("schemas")
    if not isinstance(trust_roots, list) or not isinstance(keychain, list):
        raise ContractGenerationError("architecture trust/keychain categories are missing")
    if not isinstance(schemas, dict):
        raise ContractGenerationError("architecture schemas are missing")

    return {
        "schemaVersion": 1,
        "generatedBy": {
            "name": GENERATOR_NAME,
            "version": GENERATOR_VERSION,
        },
        "app": {
            "minimumMacOS": product.get("minimumMacOS"),
            "architectures": product.get("architectures"),
        },
        "identifiers": {
            "app": identifiers.get("application"),
            "helper": identifiers.get("helper"),
            "helperMachService": identifiers.get("helperMachService"),
            "cli": None,
            "appGroup": identifiers.get("appGroup"),
        },
        "protocols": {
            "helper": helper_contract,
            "automation": None,
        },
        "cli": {
            "availability": "absent",
            "bundleIdentifier": None,
            "protocol": None,
            "schemaVersions": [],
            "commands": [],
            "options": [],
            "exitCodes": {},
            "errorCodes": {},
            "environmentVariables": [],
        },
        "appIntents": {
            "availability": "absent",
            "intentTypeNames": [],
            "entityTypes": [],
            "enumTypes": [],
            "shortcutIdentifiers": [],
        },
        "schemas": schemas,
        "trustRoots": trust_roots,
        "helpTopics": help_topic_ids(repo),
        "configuration": configuration_contract(repo),
        "userDefaults": user_defaults_contract(repo),
        "keychain": keychain,
        "urlSchemes": [],
        "absentSurfaces": sorted(required_absent),
        "sources": sorted(
            set(architecture.get("sources", []))
            | {
                "VelaIPC/VelaHelperError.swift",
                "Vela/Core/ConfigurationWorkbench/ConfigurationModels.swift",
                "Vela/Core/Privileged/TunPreferences.swift",
                "Vela/Core/Updates/UpdateController.swift",
                "Vela/Core/CoreLifecycle/CoreLifecycleController.swift",
                "Vela/Core/Hardening/PublicBetaEvidenceController.swift",
                "Vela/Core/Hardening/PublicBetaSafeMode.swift",
                "Vela/Resources/Help/help-index.json",
            }
        ),
    }


def hashes_manifest(
    public: dict[str, Any],
    intents: dict[str, Any],
) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "algorithm": "SHA-256",
        "canonicalization": "UTF-8 JSON; sorted keys; no insignificant whitespace",
        "publicContract": PUBLIC_CONTRACT_NAME,
        "publicContractSHA256": canonical_sha256(public),
        "appIntentRegistry": APP_INTENT_REGISTRY_NAME,
        "appIntentRegistrySHA256": canonical_sha256(intents),
    }


def build_contracts(repo: Path) -> dict[str, dict[str, Any]]:
    architecture = architecture_manifest(repo)
    public = public_contract(repo, architecture)
    intents = app_intent_registry(architecture)
    return {
        PUBLIC_CONTRACT_NAME: public,
        APP_INTENT_REGISTRY_NAME: intents,
        HASHES_NAME: hashes_manifest(public, intents),
    }


def write_or_verify(
    path: Path,
    value: dict[str, Any],
    verify: bool,
) -> None:
    expected = pretty_bytes(value)
    if verify:
        try:
            actual = path.read_bytes()
        except OSError as error:
            raise ContractGenerationError(f"cannot verify {path}: {error}") from error
        if actual != expected:
            raise ContractGenerationError(f"generated contract drifted: {path}")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(expected)


def main() -> int:
    default_repo = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(
        description="Generate Vela public contracts from current production sources"
    )
    parser.add_argument("--repository-root", default=str(default_repo))
    parser.add_argument("--output-dir", default="Contracts/v1")
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()

    repo = Path(args.repository_root).resolve()
    output = Path(args.output_dir)
    if not output.is_absolute():
        output = repo / output
    try:
        contracts = build_contracts(repo)
        for name, value in contracts.items():
            write_or_verify(output / name, value, args.verify)
    except (ContractGenerationError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    action = "verified" if args.verify else "generated"
    print(f"Vela public contracts {action}: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
