#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

from json_schema import SchemaError, validate


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("plan")
    parser.add_argument("output")
    args = parser.parse_args()
    try:
        plan_path = Path(args.plan)
        raw = plan_path.read_bytes()
        plan = json.loads(raw)
        schema = json.loads(
            (Path(__file__).resolve().parents[1] / "schemas/fault-plan.schema.json").read_text(encoding="utf-8")
        )
        validate(plan, schema)
        metadata_path = plan_path.with_name("fault-plan-metadata.json")
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        metadata_schema = json.loads(
            (Path(__file__).resolve().parents[1] / "schemas/fault-plan-metadata.schema.json").read_text(encoding="utf-8")
        )
        validate(metadata, metadata_schema)
        if metadata["planID"] != plan["planID"]:
            raise RuntimeError("fault plan metadata planID mismatch")
        metadata_by_id = {item["id"]: item for item in metadata["scenarios"]}
        if len(metadata_by_id) != len(metadata["scenarios"]) or set(metadata_by_id) != {
            item["id"] for item in plan["scenarios"]
        }:
            raise RuntimeError("fault plan metadata coverage mismatch")
        plan_hash = hashlib.sha256(raw).hexdigest()
        rows = []
        for index, scenario in enumerate(plan["scenarios"], start=1):
            rows.append(
                {
                    "testCaseID": f"{plan['planID']}:{index}:{scenario['id']}",
                    "planSHA256": plan_hash,
                    "seed": plan["seed"],
                    "scenario": scenario,
                    "orchestration": metadata_by_id[scenario["id"]],
                    "status": "notRun",
                    "observedSafeState": None,
                    "cleanupStatus": "notRun",
                    "evidence": [],
                }
            )
        output = Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        if output.exists():
            raise RuntimeError(f"refusing to overwrite {output}")
        descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump({"schemaVersion": 1, "cases": rows}, handle, indent=2, sort_keys=True)
            handle.write("\n")
    except (OSError, KeyError, RuntimeError, ValueError, json.JSONDecodeError, SchemaError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"Generated {len(rows)} deterministic fault cases; none were executed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
