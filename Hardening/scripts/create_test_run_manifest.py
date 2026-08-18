#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import subprocess
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

from json_schema import SchemaError, validate


def git(repo: Path, *args: str, check: bool = True) -> str:
    result = subprocess.run(
        ["git", *args], cwd=repo, text=True, capture_output=True, check=False
    )
    if check and result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"git {' '.join(args)} failed")
    return result.stdout.strip()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", default=".")
    parser.add_argument("--build", type=int, required=True)
    parser.add_argument(
        "--core-version",
        required=True,
        help="exact active Core ID/version observed on the test candidate",
    )
    parser.add_argument("--channel", choices=["development", "beta", "stable"], required=True)
    parser.add_argument("--macos-build", required=True)
    parser.add_argument("--memory-gb", type=int, required=True)
    parser.add_argument("--user-type", choices=["standard", "admin"], required=True)
    parser.add_argument("--hardware-category", default="Apple Silicon")
    parser.add_argument("--power", choices=["AC", "battery"], default="AC")
    parser.add_argument("--thermal-state", choices=["nominal", "fair", "serious", "critical", "unknown"], default="unknown")
    parser.add_argument("--locale", default="en")
    parser.add_argument("--appearance", choices=["light", "dark", "highContrastLight", "highContrastDark"], default="dark")
    parser.add_argument("--network-scenario", default="offline")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    repo = Path(args.repository_root).resolve()
    try:
        architecture_path = repo / "Hardening/config/architecture-freeze.json"
        architecture_raw = architecture_path.read_bytes()
        architecture = json.loads(architecture_raw)
        components = {item["name"]: item for item in architecture["bundledComponents"]}
        expected_build = int(architecture["product"]["build"])
        if args.build != expected_build:
            raise RuntimeError(
                f"--build {args.build} does not match architecture freeze {expected_build}"
            )
        if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,95}", args.core_version) is None:
            raise RuntimeError("--core-version must be a bounded non-sensitive Core ID/version")
        exact_tag = git(repo, "describe", "--tags", "--exact-match", "HEAD", check=False) or None
        manifest = {
            "schemaVersion": 1,
            "runID": str(uuid.uuid4()),
            "createdAt": datetime.now(timezone.utc).isoformat(),
            "completedAt": None,
            "source": {
                "commit": git(repo, "rev-parse", "HEAD"),
                "tag": exact_tag,
                "build": args.build,
                "channel": args.channel,
                "dirty": bool(git(repo, "status", "--porcelain")),
                "architectureFreezeSHA256": hashlib.sha256(architecture_raw).hexdigest(),
            },
            "components": {
                "app": components["Vela"]["version"],
                "helper": components["VelaHelper"]["version"],
                "helperProtocol": architecture["protocols"]["helper"]["maximum"],
                "cli": None,
                "mihomo": components["mihomo"]["version"],
                "core": args.core_version,
            },
            "environment": {
                "machineID": str(uuid.uuid4()),
                "hardwareCategory": args.hardware_category,
                "memoryGB": args.memory_gb,
                "macOSBuild": args.macos_build,
                "architecture": platform.machine(),
                "power": args.power,
                "thermalState": args.thermal_state,
                "userType": args.user_type,
                "locale": args.locale,
                "appearance": args.appearance,
                "accessibility": [],
                "networkScenario": args.network_scenario,
                "serialNumberCollected": False,
                "realUserNameCollected": False,
                "syntheticDataOnly": True,
            },
            "faultPlan": None,
            "tests": [],
            "cleanup": {
                "status": "notRun",
                "managedPIDs": [],
                "ownedTunInterfaces": [],
                "systemProxyMatches": False,
                "routeStateMatches": False,
                "temporaryResourcesRemoved": False,
                "evidence": [],
            },
        }
        if manifest["environment"]["architecture"] != "arm64":
            raise RuntimeError("test evidence is supported only on arm64")
        schema = json.loads(
            (repo / "Hardening/schemas/test-run-manifest.schema.json").read_text(
                encoding="utf-8"
            )
        )
        validate(manifest, schema)
        output = Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        if output.exists():
            raise RuntimeError(f"refusing to overwrite {output}")
        descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(manifest, handle, indent=2, sort_keys=True)
            handle.write("\n")
    except (
        OSError,
        KeyError,
        ValueError,
        RuntimeError,
        json.JSONDecodeError,
        SchemaError,
    ) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
