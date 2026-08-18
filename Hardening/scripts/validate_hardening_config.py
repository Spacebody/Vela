#!/usr/bin/env python3
"""Validate all V0.8 hardening policy/config files without external packages."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

from json_schema import SchemaError, validate
from validate_stop_ship import blockers


class ConfigError(RuntimeError):
    pass


CONFIG_SCHEMAS = {
    "architecture-freeze.json": "architecture-freeze.schema.json",
    "attack-surface.json": "attack-surface.schema.json",
    "evidence-policy.json": "evidence-policy.schema.json",
    "fault-plan.json": "fault-plan.schema.json",
    "fault-plan-metadata.json": "fault-plan-metadata.schema.json",
    "migration-matrix.json": "migration-matrix.schema.json",
    "performance-budgets.json": "performance-budget.schema.json",
    "performance-baseline.json": "performance-results.schema.json",
    "soak-matrix.json": "soak-matrix.schema.json",
    "beta-policy.json": "beta-policy.schema.json",
    "stop-ship-policy.json": "stop-ship-policy.schema.json",
    "release-readiness.json": "release-readiness.schema.json",
}

POSTBUILD_CONDITIONS = {
    "soak24hIncomplete",
    "soak72hIncomplete",
    "multiUserLabIncomplete",
    "destructiveTunMatrixIncomplete",
    "signedNotarizedBetaArtifactMissing",
    "sbomProvenanceAttestationMissing",
    "criticalAccessibilityBlocker",
    "approvedBudgetExceeded",
    "tunRouteOrSystemProxyResidue",
}


def release_blockers(
    policy: dict[str, Any], readiness: dict[str, Any], channel: str, phase: str
) -> list[str]:
    found = blockers(policy, readiness, channel)
    if phase == "candidate-stage":
        return [item for item in found if item not in POSTBUILD_CONDITIONS]
    return found

def load(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ConfigError(f"cannot load {path}: {error}") from error
    if not isinstance(value, dict):
        raise ConfigError(f"{path} must contain an object")
    return value


def unique(items: list[dict[str, Any]], key: str, label: str) -> None:
    values = [item.get(key) for item in items]
    if len(values) != len(set(values)):
        raise ConfigError(f"duplicate {label}: {values}")


def swift_fault_points(repo: Path) -> set[str]:
    source = (repo / "Vela/Core/FaultInjection/FaultInjectionTypes.swift").read_text(
        encoding="utf-8"
    )
    match = re.search(
        r"enum\s+FaultInjectionPoint\b.*?\{(.*?)\n\}", source, re.S
    )
    if match is None:
        raise ConfigError("cannot parse FaultInjectionPoint from production DEBUG source")
    points = set(re.findall(r'^\s*case\s+\w+\s*=\s*"([^"]+)"', match.group(1), re.M))
    if len(points) != 35:
        raise ConfigError(f"expected 35 fixed FaultInjectionPoint values, found {len(points)}")
    return points


def validate_fault_plan(
    plan: dict[str, Any], metadata: dict[str, Any], schema: dict[str, Any], repo: Path
) -> None:
    scenarios = plan["scenarios"]
    unique(scenarios, "id", "fault scenario ID")
    triggers = [(item["point"], item["occurrence"]) for item in scenarios]
    if len(triggers) != len(set(triggers)):
        raise ConfigError("fault plan contains duplicate point/occurrence triggers")
    source_points = swift_fault_points(repo)
    schema_points = set(
        schema["properties"]["scenarios"]["items"]["properties"]["point"]["enum"]
    )
    if schema_points != source_points:
        raise ConfigError("fault-plan schema does not exactly match the 35 Swift fixed points")
    unknown = {item["point"] for item in scenarios} - source_points
    if unknown:
        raise ConfigError(f"fault plan contains points absent from Swift: {sorted(unknown)}")
    if metadata["planID"] != plan["planID"]:
        raise ConfigError("fault plan metadata planID mismatch")
    metadata_scenarios = metadata["scenarios"]
    unique(metadata_scenarios, "id", "fault metadata scenario ID")
    if {item["id"] for item in metadata_scenarios} != {item["id"] for item in scenarios}:
        raise ConfigError("fault metadata coverage does not exactly match executable plan")
    metadata_by_id = {item["id"]: item for item in metadata_scenarios}
    forbidden_tokens = ("shell", "command", "arbitrarypath", "killall", "wildcard", "unknownpid")
    filesystem_points = {
        "file.write", "profile.commit.atomicReplace", "testFilesystem.insufficientDisk",
        "testFilesystem.permissionDenied", "configuration.compile", "configuration.apply",
        "appUpdate.journal", "core.install", "supportBundle.write", "help.export",
    }
    path_points = {
        "file.write", "profile.commit.atomicReplace", "configuration.compile",
        "configuration.validation", "configuration.apply", "appUpdate.journal",
        "core.install", "help.export", "supportBundle.write",
    }
    for scenario in scenarios:
        metadata_item = metadata_by_id[scenario["id"]]
        serialized = json.dumps(
            {"point": scenario["point"], "effect": scenario["effect"], "metadata": metadata_item},
            sort_keys=True,
        ).lower().replace(" ", "")
        if any(token in serialized for token in forbidden_tokens):
            raise ConfigError(f"unsafe fault scenario vocabulary: {scenario['id']}")
        kind = scenario["effect"]["kind"]
        point = scenario["point"]
        if kind == "httpStatus" and point not in {"subscription.response", "controller.httpResponse"}:
            raise ConfigError(f"incompatible HTTP fault effect: {scenario['id']}")
        if kind == "closeWebSocket" and point != "connections.webSocket.disconnect":
            raise ConfigError(f"incompatible WebSocket fault effect: {scenario['id']}")
        if kind in {"insufficientDisk", "permissionDenied"} and point not in filesystem_points:
            raise ConfigError(f"incompatible filesystem fault effect: {scenario['id']}")
        if kind == "testPath" and point not in path_points:
            raise ConfigError(f"incompatible path fault effect: {scenario['id']}")
        if kind == "clockJump" and (point != "clock.jump" or scenario["effect"]["seconds"] == 0):
            raise ConfigError(f"incompatible clock fault effect: {scenario['id']}")
        if kind == "sleepWake" and point != "system.sleepWake":
            raise ConfigError(f"incompatible sleep/wake fault effect: {scenario['id']}")
        if kind == "ownedProcessExit" and point not in {"process.ownedTermination", "core.probation.processExit"}:
            raise ConfigError(f"incompatible process-exit fault effect: {scenario['id']}")
        if kind == "ownedProcessExit" and not scenario["destructive"]:
            raise ConfigError(f"owned process exit must be marked destructive: {scenario['id']}")
        if scenario["destructive"]:
            preconditions = " ".join(metadata_item["preconditions"]).lower()
            if "signed" not in preconditions or "cleanup preflight" not in preconditions:
                raise ConfigError(f"destructive fault lacks signed/cleanup preflight: {scenario['id']}")


def validate_migration(matrix: dict[str, Any], require_complete: bool) -> None:
    sources = matrix["sources"]
    versions = [item["version"] for item in sources]
    if versions != ["0.1", "0.2", "0.3", "0.4", "0.5", "0.6", "0.7"]:
        raise ConfigError(f"migration source order/coverage is wrong: {versions}")
    for source in sources:
        complete = source["status"] in {"generated", "validated"}
        evidence = all(
            source[key] is not None
            for key in ("producingCommit", "generatorVersion", "fixtureSHA256", "fixturePath")
        )
        if complete != evidence:
            raise ConfigError(f"migration source has inconsistent evidence: {source['version']}")
    if require_complete:
        missing = [item["version"] for item in sources if item["status"] != "validated"]
        if missing:
            raise ConfigError(f"historical migration evidence is incomplete: {missing}")


def validate_performance(budgets: dict[str, Any], baseline: dict[str, Any], require_calibrated: bool) -> None:
    unique(budgets["budgets"], "id", "performance budget ID")
    calibration = budgets["calibration"]
    pending = calibration["status"] == "pending"
    ceilings = [item["approvedAbsoluteCeiling"] for item in budgets["budgets"]]
    if pending:
        if any(value is not None for value in ceilings):
            raise ConfigError("pending calibration must not enforce absolute ceilings")
        if any(calibration[key] is not None for key in ("referenceEnvironmentID", "approvedBy", "approvedAt", "evidencePath")):
            raise ConfigError("pending calibration contains approval fields")
        if baseline["status"] != "unmeasured" or baseline["metrics"]:
            raise ConfigError("pending calibration cannot have a committed baseline")
    else:
        if any(value is None for value in ceilings):
            raise ConfigError("approved calibration is missing an absolute ceiling")
        if baseline["status"] != "approvedBaseline":
            raise ConfigError("approved calibration requires an approved baseline")
        if baseline["environmentID"] != calibration["referenceEnvironmentID"]:
            raise ConfigError("performance baseline environment does not match calibration")
    if require_calibrated and pending:
        raise ConfigError("performance budgets have not been calibrated and approved")


def validate_soak(matrix: dict[str, Any]) -> None:
    scenarios = matrix["scenarios"]
    unique(scenarios, "id", "soak scenario ID")
    for scenario in scenarios:
        if scenario["perIterationTimeoutSeconds"] > scenario["totalTimeoutSeconds"]:
            raise ConfigError(f"iteration timeout exceeds total timeout: {scenario['id']}")
        if scenario["destructive"]:
            capabilities = set(scenario["requiredMachineCapabilities"])
            if "signedBuild" not in capabilities:
                raise ConfigError(f"destructive soak lacks signedBuild capability: {scenario['id']}")


def validate_beta(policy: dict[str, Any]) -> None:
    waves = [item["id"] for item in policy["waves"]]
    if waves != ["dogfood", "invite", "publicBeta", "stable"]:
        raise ConfigError(f"Beta wave order is wrong: {waves}")


def validate_stop_ship(policy: dict[str, Any], readiness: dict[str, Any]) -> None:
    unique(policy["rules"], "id", "Stop-Ship rule ID")
    unique(readiness["issues"], "id", "issue ID")
    unique(readiness["conditions"], "id", "readiness condition ID")
    conditions = {item["id"] for item in readiness["conditions"]}
    policy_conditions = {item["condition"] for item in policy["rules"] if "condition" in item}
    missing = policy_conditions - conditions
    if missing:
        raise ConfigError(f"Stop-Ship conditions have no assessment: {sorted(missing)}")


def verify_truthful_blockers(repo: Path, readiness: dict[str, Any]) -> None:
    active = {item["id"]: item["active"] for item in readiness["conditions"]}
    documentation = load(repo / "Release/config/documentation.json")
    if documentation.get("securityContact") is None and not active.get("securityContactUnprovisioned"):
        raise ConfigError("missing security contact is not an active Stop-Ship condition")
    release = load(repo / "Release/config/release.json")
    update = release.get("updates", {})
    placeholder_update = str(update.get("feedURL", "")).endswith(".invalid/vela/appcast.xml") or str(update.get("publicEDKey", "")).startswith("__")
    if placeholder_update and not active.get("productionAppUpdateTrustUnprovisioned"):
        raise ConfigError("placeholder App update trust is not an active Stop-Ship condition")
    core_source = (repo / "VelaIPC/CoreCatalogTrust.swift").read_text(encoding="utf-8")
    if "all: [CoreCatalogTrustRoot] = []" in core_source and not active.get("productionCoreCatalogTrustUnprovisioned"):
        raise ConfigError("empty Core trust root is not an active Stop-Ship condition")
    compatibility = load(repo / "Release/config/compatibility.json")
    requirements = release.get("releaseRequirements", {})
    absent_required_surfaces = (
        requirements.get("requireCLI") is True
        and requirements.get("requireAutomationProtocol") is True
        and requirements.get("requireSceneSchema") is True
        and compatibility.get("components", {}).get("cli") is None
        and compatibility.get("cliProtocol") is None
        and compatibility.get("automationProtocol") is None
        and compatibility.get("schemas", {}).get("scene") is None
    )
    if absent_required_surfaces and not active.get("releaseRequiredSurfacesAbsent"):
        raise ConfigError("Release-required absent surfaces are not an active Stop-Ship condition")
    release_manifest_generator = (repo / "Release/scripts/generate_release_manifest.py").read_text(
        encoding="utf-8"
    )
    if (
        "architectureFreezeSHA256" not in release_manifest_generator
        and not active.get("releaseManifestArchitectureBindingMissing")
    ):
        raise ConfigError("missing Release-manifest architecture binding is not an active Stop-Ship condition")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", default=".")
    parser.add_argument("--require-migration-evidence", action="store_true")
    parser.add_argument("--require-calibrated-performance", action="store_true")
    parser.add_argument("--release-gate", choices=["dogfood", "invite", "publicBeta", "stable"])
    parser.add_argument(
        "--release-phase",
        choices=["candidate-stage", "promotion"],
        default="promotion",
    )
    args = parser.parse_args()
    repo = Path(args.repository_root).resolve()
    config_root = repo / "Hardening/config"
    schema_root = repo / "Hardening/schemas"

    try:
        values: dict[str, dict[str, Any]] = {}
        schemas: dict[str, dict[str, Any]] = {}
        for config_name, schema_name in CONFIG_SCHEMAS.items():
            value = load(config_root / config_name)
            schema = load(schema_root / schema_name)
            validate(value, schema)
            values[config_name] = value
            schemas[config_name] = schema

        architecture = subprocess.run(
            [sys.executable, str(repo / "Hardening/scripts/validate_architecture_freeze.py"), "--repository-root", str(repo)],
            text=True, capture_output=True,
        )
        if architecture.returncode != 0:
            raise ConfigError(architecture.stderr.strip() or "architecture validation failed")

        validate_fault_plan(
            values["fault-plan.json"],
            values["fault-plan-metadata.json"],
            schemas["fault-plan.json"],
            repo,
        )
        candidate_gate = args.release_gate in {"invite", "publicBeta", "stable"}
        validate_migration(
            values["migration-matrix.json"],
            args.require_migration_evidence or candidate_gate,
        )
        validate_performance(
            values["performance-budgets.json"],
            values["performance-baseline.json"],
            args.require_calibrated_performance or candidate_gate,
        )
        validate_soak(values["soak-matrix.json"])
        validate_beta(values["beta-policy.json"])
        validate_stop_ship(values["stop-ship-policy.json"], values["release-readiness.json"])
        verify_truthful_blockers(repo, values["release-readiness.json"])
        if args.release_gate:
            found = release_blockers(
                values["stop-ship-policy.json"],
                values["release-readiness.json"],
                args.release_gate,
                args.release_phase,
            )
            if found:
                raise ConfigError(f"Stop-Ship active for {args.release_gate}: {found}")
    except (OSError, ConfigError, SchemaError, json.JSONDecodeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"Validated {len(CONFIG_SCHEMAS)} hardening config files.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
