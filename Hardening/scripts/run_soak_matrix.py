#!/usr/bin/env python3
"""Safe-by-default soak orchestrator with a scenario-wide deadline."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from json_schema import SchemaError, validate


class SoakError(RuntimeError):
    pass


def load(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise SoakError(f"{path} must contain an object")
    return value


def command(mapping: dict[str, Any], identifier: str) -> list[str]:
    value = mapping.get("commands", {}).get(identifier)
    if not isinstance(value, dict) or set(value) != {"argv"}:
        raise SoakError(f"missing or invalid command mapping: {identifier}")
    argv = value["argv"]
    if (
        not isinstance(argv, list)
        or not argv
        or not all(isinstance(item, str) and item and "\x00" not in item for item in argv)
    ):
        raise SoakError(f"invalid argv mapping: {identifier}")
    forbidden_executables = {
        "bash", "zsh", "sh", "fish", "sudo", "rm", "kill", "pkill", "killall",
        "route", "ifconfig", "networksetup", "systemsetup", "scutil", "diskutil",
        "launchctl", "osascript",
    }
    executable = Path(argv[0]).name.lower()
    if executable in forbidden_executables:
        raise SoakError(f"command mapping uses a forbidden direct mutation primitive: {identifier}")
    return argv


def machine_allows(machine: dict[str, Any], scenario: dict[str, Any]) -> None:
    required_true = {
        "dedicated": True,
        "signedBuildVerified": True,
        "syntheticDataOnly": True,
        "cleanupPreflightPassed": True,
    }
    for key, expected in required_true.items():
        if machine.get(key) is not expected:
            raise SoakError(f"destructive run requires machine {key}=true")
    missing = set(scenario["requiredMachineCapabilities"]) - set(machine.get("capabilities", []))
    if missing:
        raise SoakError(f"test machine lacks capabilities: {sorted(missing)}")


def sanitized_environment(run_id: str, synthetic_home: str) -> dict[str, str]:
    allowed = ("TMPDIR", "DEVELOPER_DIR", "LANG", "LC_ALL")
    result = {key: os.environ[key] for key in allowed if key in os.environ}
    result["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    result["HOME"] = synthetic_home
    result["VELA_HARDENING_RUN_ID"] = run_id
    return result


def run_bounded(argv: list[str], timeout: float, environment: dict[str, str]) -> None:
    process = subprocess.Popen(argv, env=environment, start_new_session=True)
    try:
        return_code = process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=5)
        except (ProcessLookupError, subprocess.TimeoutExpired):
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        raise subprocess.TimeoutExpired(argv, timeout) from None
    if return_code != 0:
        raise subprocess.CalledProcessError(return_code, argv)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("matrix")
    parser.add_argument("--command-map")
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--only", action="append", default=[])
    parser.add_argument("--machine-manifest")
    parser.add_argument("--confirm-dedicated-machine", action="store_true")
    parser.add_argument("--output")
    args = parser.parse_args()
    run_id = str(uuid.uuid4())
    try:
        matrix_path = Path(args.matrix)
        matrix = load(matrix_path)
        schema_root = Path(__file__).resolve().parents[1] / "schemas"
        validate(matrix, load(schema_root / "soak-matrix.schema.json"))
        selected = [
            item for item in matrix["scenarios"]
            if not args.only or item["id"] in set(args.only)
        ]
        if not selected:
            raise SoakError("no scenarios selected")
        unknown = set(args.only) - {item["id"] for item in selected}
        if unknown:
            raise SoakError(f"unknown scenarios: {sorted(unknown)}")

        mapping: dict[str, Any] = {}
        mapping_hash: str | None = None
        if args.command_map:
            mapping_path = Path(args.command_map)
            raw = mapping_path.read_bytes()
            mapping = json.loads(raw)
            if set(mapping) != {"schemaVersion", "commands"} or mapping["schemaVersion"] != 1:
                raise SoakError("invalid command-map envelope")
            mapping_hash = hashlib.sha256(raw).hexdigest()
        if args.execute and (not args.command_map or not args.output):
            raise SoakError("--execute requires --command-map and --output")

        destructive = [item for item in selected if item["destructive"]]
        machine: dict[str, Any] | None = None
        if destructive and args.execute:
            if os.environ.get("VELA_RUN_DESTRUCTIVE_BETA_TESTS") != "1":
                raise SoakError("destructive execution requires VELA_RUN_DESTRUCTIVE_BETA_TESTS=1")
            if not args.confirm_dedicated_machine or not args.machine_manifest:
                raise SoakError("destructive execution requires explicit dedicated-machine confirmation and manifest")
            machine = load(Path(args.machine_manifest))
            validate(machine, load(schema_root / "test-machine-manifest.schema.json"))
            for scenario in destructive:
                machine_allows(machine, scenario)

        results: list[dict[str, Any]] = []
        with tempfile.TemporaryDirectory(prefix="vela-soak-home-") as synthetic_home:
            environment = sanitized_environment(run_id, synthetic_home)
            for scenario in selected:
                print(
                    f"{scenario['id']}: repetitions={scenario['repetitions']} "
                    f"destructive={scenario['destructive']} totalTimeout={scenario['totalTimeoutSeconds']}s"
                )
                if not args.execute:
                    results.append({"id": scenario["id"], "status": "notRun", "iterations": 0, "cleanup": "notRun"})
                    continue
                argv = command(mapping, scenario["commandID"])
                cleanup = command(mapping, scenario["cleanupID"])
                started = time.monotonic()
                completed = 0
                status = "passed"
                result_code = "success"
                cleanup_status = "notRun"
                try:
                    for index in range(scenario["repetitions"]):
                        remaining = scenario["totalTimeoutSeconds"] - (time.monotonic() - started)
                        if remaining <= 0:
                            raise subprocess.TimeoutExpired(argv, scenario["totalTimeoutSeconds"])
                        timeout = min(float(scenario["perIterationTimeoutSeconds"]), remaining)
                        print(f"  iteration {index + 1}/{scenario['repetitions']}")
                        run_bounded(argv, timeout, environment)
                        completed += 1
                except subprocess.TimeoutExpired:
                    status = "failed"
                    result_code = "scenarioTimeout"
                except subprocess.CalledProcessError:
                    status = "failed"
                    result_code = "commandFailed"
                finally:
                    try:
                        run_bounded(cleanup, 300, environment)
                        cleanup_status = "passed"
                    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                        cleanup_status = "failed"
                        status = "failed"
                        result_code = "cleanupFailed"
                results.append(
                    {
                        "id": scenario["id"],
                        "status": status,
                        "stableResultCode": result_code,
                        "iterations": completed,
                        "cleanup": cleanup_status,
                        "durationSeconds": round(time.monotonic() - started, 3),
                    }
                )

        if args.execute:
            output = Path(args.output)
            if output.exists():
                raise SoakError(f"refusing to overwrite {output}")
            output.parent.mkdir(parents=True, exist_ok=True)
            payload = {
                "schemaVersion": 1,
                "runID": run_id,
                "createdAt": datetime.now(timezone.utc).isoformat(),
                "matrixSHA256": hashlib.sha256(matrix_path.read_bytes()).hexdigest(),
                "commandMapSHA256": mapping_hash,
                "destructiveGateUsed": bool(destructive),
                "results": results,
                "passed": all(item["status"] == "passed" and item["cleanup"] == "passed" for item in results),
            }
            output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            os.chmod(output, 0o600)
            if not payload["passed"]:
                return 1
    except (OSError, KeyError, ValueError, json.JSONDecodeError, SchemaError, SoakError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    if not args.execute:
        print("Dry-run only; no scenario or cleanup command was executed.")
    else:
        print("Selected soak scenarios and cleanup commands passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
