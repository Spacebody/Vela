#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sys
from collections import Counter
from pathlib import Path

from json_schema import SchemaError, validate
from validate_test_evidence import evidence_path


PASSING = {"passed"}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifests", nargs="+")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        schema = json.loads(
            (Path(__file__).resolve().parents[1] / "schemas/test-run-manifest.schema.json").read_text(
                encoding="utf-8"
            )
        )
        run_paths = [Path(value) for value in args.manifests]
        runs = [json.loads(path.read_text(encoding="utf-8")) for path in run_paths]
        for path, run in zip(run_paths, runs, strict=True):
            validate(run, schema)
            if run["completedAt"] is None:
                raise RuntimeError(f"incomplete run has no completedAt: {path}")
            for test in run["tests"]:
                for descriptor in test["evidence"]:
                    evidence_path(path.parent, descriptor)
            for descriptor in run["cleanup"]["evidence"]:
                evidence_path(path.parent, descriptor)
        run_ids = [run["runID"] for run in runs]
        if len(run_ids) != len(set(run_ids)):
            raise RuntimeError("duplicate test run IDs cannot be aggregated")
        source_bindings = {
            (
                run["source"]["commit"], run["source"]["build"],
                run["source"]["architectureFreezeSHA256"],
            )
            for run in runs
        }
        if len(source_bindings) != 1:
            raise RuntimeError("soak runs do not bind the same source/build/freeze")
        statuses: Counter[str] = Counter()
        cleanup_failures = 0
        test_count = 0
        for run in runs:
            tests = run.get("tests", [])
            if not tests:
                statuses["missingTests"] += 1
            for test in tests:
                status = str(test.get("status", "missingStatus"))
                statuses[status] += 1
                test_count += 1
            cleanup = run.get("cleanup", {})
            if (
                cleanup.get("status") != "passed"
                or cleanup.get("managedPIDs")
                or cleanup.get("ownedTunInterfaces")
                or cleanup.get("systemProxyMatches") is not True
                or cleanup.get("routeStateMatches") is not True
                or cleanup.get("temporaryResourcesRemoved") is not True
            ):
                cleanup_failures += 1
        passed = (
            bool(runs)
            and test_count > 0
            and cleanup_failures == 0
            and set(statuses).issubset(PASSING)
        )
        summary = {
            "schemaVersion": 1,
            "runCount": len(runs),
            "testCount": test_count,
            "testStatuses": dict(sorted(statuses.items())),
            "cleanupFailures": cleanup_failures,
            "passed": passed,
        }
        output = Path(args.output)
        if output.exists():
            raise RuntimeError(f"refusing to overwrite {output}")
        output.parent.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(summary, handle, indent=2, sort_keys=True)
            handle.write("\n")
    except (OSError, KeyError, RuntimeError, ValueError, json.JSONDecodeError, SchemaError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    if not passed:
        print("Soak aggregation reports incomplete tests or cleanup failures.", file=sys.stderr)
        return 1
    print(f"Aggregated {len(runs)} passing soak run(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
