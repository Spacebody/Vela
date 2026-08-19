#!/usr/bin/env python3
"""Verify generated architecture files and gate freeze changes behind an ADR."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


class ValidationError(RuntimeError):
    pass


def load(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValidationError(f"cannot load {path}: {error}") from error
    if not isinstance(value, dict):
        raise ValidationError(f"{path} must contain an object")
    return value


def canonical(value: dict[str, Any]) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def digest_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def validate_semantics(architecture: dict[str, Any], attack: dict[str, Any]) -> None:
    expected_sections = {
        "schemaVersion", "generatorVersion", "sources", "surfaceDiscovery", "product", "identifiers",
        "protocols", "schemas", "trustRoots", "bundledComponents",
        "keychainCategories", "filesystem", "networkEndpointCategories",
        "capabilities", "absentSurfaces", "releaseSecurity",
    }
    require(set(architecture) == expected_sections, "architecture sections changed")
    require(architecture["schemaVersion"] == 1, "unsupported architecture schema")
    discovery = architecture["surfaceDiscovery"]
    require(discovery.get("scannedFileCount", 0) >= 100, "production surface discovery is unexpectedly narrow")
    for name in (
        "sourcePathListSHA256", "securitySignalSHA256", "urlLiteralSHA256",
        "filesystemLiteralSHA256",
    ):
        require(
            re.fullmatch(r"[0-9a-f]{64}", str(discovery.get(name, ""))) is not None,
            f"invalid surface-discovery fingerprint {name}",
        )
    require(architecture["product"].get("architectures") == ["arm64"], "architecture is not arm64-only")

    identifiers = architecture["identifiers"]
    require(identifiers.get("application") == "dev.yilin.Vela", "App identifier changed")
    require(identifiers.get("helper") == "dev.yilin.Vela.Helper", "Helper identifier changed")
    require(identifiers.get("helperMachService") == identifiers.get("helper"), "Mach service changed")
    require(identifiers.get("cli") is None, "manifest invents a production CLI")
    require(identifiers.get("appGroup") is None, "manifest invents an App Group")
    require(identifiers.get("appIntentIdentifiers") == [], "manifest invents App Intents")

    protocols = architecture["protocols"]
    helper = protocols.get("helper", {})
    require(helper.get("minimum") == 2 and helper.get("maximum") == 2, "Helper protocol must remain v2")
    methods = helper.get("methods")
    require(isinstance(methods, list) and len(methods) == 19, "Helper must expose exactly 19 RPCs")
    require(helper.get("methodCount") == len(methods), "Helper RPC count is inconsistent")
    require(len(methods) == len(set(methods)), "Helper RPC names are duplicated")
    require(protocols.get("automation") is None, "manifest invents Automation protocol")
    require(protocols.get("cli") is None, "manifest invents CLI protocol")
    require(architecture["schemas"].get("scene") == 1, "SceneStore schema must remain v1")

    components = {item.get("name"): item for item in architecture["bundledComponents"]}
    require(components.get("VelaHelper", {}).get("version") == "0.6.0", "Helper version must remain 0.6.0")
    require(components.get("mihomo", {}).get("version") == "v1.19.29", "Mihomo version changed")
    require(components.get("Sparkle", {}).get("version") == "2.9.4", "Sparkle version changed")

    absent = set(architecture["absentSurfaces"])
    require(
        {"productionCLI", "productionAutomationSocket", "productionAppIntents",
         "networkExtension", "remoteAnalytics", "automaticCrashUpload", "remoteFeatureFlags"} <= absent,
        "required absent surfaces are not explicit",
    )
    require("productionSceneStore" not in absent, "manifest hides the production SceneStore")
    capabilities = set(architecture["capabilities"])
    require(
        {"sceneStore", "automaticSceneEvaluation"} <= capabilities,
        "production Scene capabilities are missing",
    )
    filesystem = architecture["filesystem"]
    for key in ("arbitraryRootPathAccepted", "arbitraryPIDAccepted", "arbitraryCommandAccepted"):
        require(filesystem.get(key) is False, f"{key} must be false")

    roots = {item.get("kind"): item for item in architecture["trustRoots"]}
    require(roots.get("developerIDTeam", {}).get("identifier") == "2E56T94S33", "Developer Team changed")
    require(roots.get("sparkleEdDSA", {}).get("status") in {"configured", "unprovisioned"}, "invalid Sparkle root state")
    require(roots.get("coreCatalogEd25519", {}).get("status") in {"configured", "unprovisioned"}, "invalid Core root state")

    expected_attack_sections = {
        "schemaVersion", "architectureManifestSHA256", "processes", "localInterfaces",
        "externalInputs", "privilegedOperations", "dataStores", "explicitlyAbsent",
    }
    require(set(attack) == expected_attack_sections, "attack-surface sections changed")
    require(attack["schemaVersion"] == 1, "unsupported attack-surface schema")
    require(
        attack["architectureManifestSHA256"] == digest_bytes(canonical(architecture)),
        "attack surface references the wrong architecture manifest",
    )
    require(attack["explicitlyAbsent"] == architecture["absentSurfaces"], "absent surfaces diverged")

    serialized = canonical(architecture) + canonical(attack)
    require(not re.search(rb"/Users/[^/<\s]+/", serialized), "manifest contains a concrete user home")
    require(not re.search(rb"(?i)(token|password|secret)=[^&\s]+", serialized), "manifest contains a secret-like query")


def git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args], cwd=repo, text=True, capture_output=True, check=check
    )


def base_file(repo: Path, revision: str, relative: str) -> bytes | None:
    result = git(repo, "show", f"{revision}:{relative}", check=False)
    if result.returncode != 0:
        return None
    return result.stdout.encode()


def changed_paths(before: Any, after: Any, prefix: str = "") -> list[str]:
    if type(before) is not type(after):
        return [prefix or "/"]
    if isinstance(before, dict):
        paths: list[str] = []
        for key in sorted(set(before) | set(after)):
            child = f"{prefix}/{key}"
            if key not in before or key not in after:
                paths.append(child)
            else:
                paths.extend(changed_paths(before[key], after[key], child))
        return paths
    if isinstance(before, list):
        return [] if before == after else [prefix or "/"]
    return [] if before == after else [prefix or "/"]


def validate_adr(path: Path, baseline_sha: str, current_sha: str) -> None:
    text = path.read_text(encoding="utf-8")
    expected_status = "BaselineRecorded" if baseline_sha == "absent" else "Accepted"
    required = {
        "Status": expected_status,
        "Baseline SHA256": baseline_sha,
        "Current SHA256": current_sha,
    }
    for label, expected in required.items():
        match = re.search(rf"^- {re.escape(label)}:\s*(\S+)\s*$", text, re.M)
        require(match is not None and match.group(1) == expected, f"{path}: invalid {label}")
    for label in ("Security owner", "Release owner"):
        match = re.search(rf"^- {re.escape(label)}:\s*(.+?)\s*$", text, re.M)
        require(match is not None, f"{path}: missing {label}")
        value = match.group(1).strip().lower()
        forbidden = {"", "tbd", "todo", "unknown", "__replace__"}
        if baseline_sha != "absent":
            forbidden.add("unassigned")
        require(value not in forbidden, f"{path}: placeholder {label}")
    for heading in ("## Change", "## Security impact", "## Compatibility", "## Tests", "## Review"):
        require(heading in text, f"{path}: missing {heading}")


def gate_against_revision(repo: Path, revision: str, architecture_path: Path) -> None:
    relative = str(architecture_path.resolve().relative_to(repo))
    before_raw = base_file(repo, revision, relative)
    current_raw = architecture_path.read_bytes()
    if before_raw == current_raw:
        return

    before_sha = "absent" if before_raw is None else digest_bytes(before_raw)
    current_sha = digest_bytes(current_raw)
    diff = git(repo, "diff", "--name-only", revision, "--", "Hardening/adr", check=False)
    untracked = git(
        repo,
        "ls-files",
        "--others",
        "--exclude-standard",
        "--",
        "Hardening/adr",
        check=False,
    )
    candidate_paths = {
        line
        for line in [*diff.stdout.splitlines(), *untracked.stdout.splitlines()]
        if line.endswith(".md")
    }
    candidates = [repo / line for line in sorted(candidate_paths)]
    if not candidates:
        raise ValidationError(
            f"architecture freeze changed ({before_sha} -> {current_sha}) without an ADR"
        )
    errors: list[str] = []
    for candidate in candidates:
        try:
            validate_adr(candidate, before_sha, current_sha)
            break
        except (OSError, ValidationError) as error:
            errors.append(str(error))
    else:
        raise ValidationError("no accepted ADR matches this freeze change: " + "; ".join(errors))

    before = {} if before_raw is None else json.loads(before_raw)
    after = load(architecture_path)
    for path in changed_paths(before, after):
        print(f"architecture change: {path}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", default=".")
    parser.add_argument("--architecture", default="Hardening/config/architecture-freeze.json")
    parser.add_argument("--attack-surface", default="Hardening/config/attack-surface.json")
    parser.add_argument("--base-revision")
    args = parser.parse_args()
    repo = Path(args.repository_root).resolve()
    architecture_path = (repo / args.architecture).resolve()
    attack_path = (repo / args.attack_surface).resolve()

    try:
        architecture = load(architecture_path)
        attack = load(attack_path)
        validate_semantics(architecture, attack)
        with tempfile.TemporaryDirectory(prefix="vela-architecture-") as directory:
            generated_architecture = Path(directory) / "architecture.json"
            generated_attack = Path(directory) / "attack.json"
            command = [
                sys.executable,
                str(Path(__file__).with_name("generate_architecture_manifest.py")),
                "--repository-root", str(repo),
                "--architecture-output", str(generated_architecture),
                "--attack-surface-output", str(generated_attack),
            ]
            result = subprocess.run(command, text=True, capture_output=True)
            require(result.returncode == 0, result.stderr.strip() or "architecture generation failed")
            require(generated_architecture.read_bytes() == architecture_path.read_bytes(), "architecture baseline is stale")
            require(generated_attack.read_bytes() == attack_path.read_bytes(), "attack-surface baseline is stale")
        if args.base_revision:
            gate_against_revision(repo, args.base_revision, architecture_path)
    except (OSError, ValueError, json.JSONDecodeError, ValidationError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print("Architecture freeze and attack surface passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
