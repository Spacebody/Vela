#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path
from typing import Any

from json_schema import SchemaError, validate


class PerformanceError(RuntimeError):
    pass


def load(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise PerformanceError(f"{path} must contain an object")
    return value


def percent(current: float, baseline: float) -> float:
    if baseline == 0:
        return 0.0 if current == 0 else math.inf
    return (current - baseline) / baseline * 100.0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("budgets")
    parser.add_argument("baseline")
    parser.add_argument("current")
    parser.add_argument("--exploratory", action="store_true", help="report unapproved relative deltas without declaring a gate")
    args = parser.parse_args()
    try:
        root = Path(__file__).resolve().parents[1]
        budgets = load(Path(args.budgets))
        baseline = load(Path(args.baseline))
        current = load(Path(args.current))
        validate(budgets, load(root / "schemas/performance-budget.schema.json"))
        result_schema = load(root / "schemas/performance-results.schema.json")
        validate(baseline, result_schema)
        validate(current, result_schema)
        approved = budgets["calibration"]["status"] == "approved"
        if not approved and not args.exploratory:
            raise PerformanceError("performance calibration is pending; refusing to declare a passing gate")
        if baseline["status"] not in ({"measured", "approvedBaseline"} if args.exploratory else {"approvedBaseline"}):
            raise PerformanceError("baseline is not measured/approved for the requested mode")
        if current["status"] == "unmeasured":
            raise PerformanceError("current performance result is unmeasured")
        if not baseline["environmentID"] or baseline["environmentID"] != current["environmentID"]:
            raise PerformanceError("performance environments are missing or incomparable")
        if approved and baseline["environmentID"] != budgets["calibration"]["referenceEnvironmentID"]:
            raise PerformanceError("baseline is not from the approved reference environment")

        budget_items = {item["id"]: item for item in budgets["budgets"]}
        if set(baseline["metrics"]) != set(budget_items) or set(current["metrics"]) != set(budget_items):
            raise PerformanceError("baseline/current metric coverage does not exactly match budgets")
        failures: list[str] = []
        for metric_id, budget in budget_items.items():
            before = baseline["metrics"][metric_id]
            after = current["metrics"][metric_id]
            if before["unit"] != budget["unit"] or after["unit"] != budget["unit"]:
                failures.append(f"{metric_id}: unit mismatch")
                continue
            if before["samples"] < budget["minimumSamples"] or after["samples"] < budget["minimumSamples"]:
                failures.append(f"{metric_id}: insufficient samples")
                continue
            if before["p95"] < before["median"] or after["p95"] < after["median"]:
                failures.append(f"{metric_id}: p95 below median")
                continue
            median_delta = percent(after["median"], before["median"])
            p95_delta = percent(after["p95"], before["p95"])
            print(f"{metric_id}: median {median_delta:+.1f}%, p95 {p95_delta:+.1f}%")
            if median_delta > budgets["relativeRegression"]["medianPercent"]:
                failures.append(f"{metric_id}: median regression")
            if p95_delta > budgets["relativeRegression"]["p95Percent"]:
                failures.append(f"{metric_id}: p95 regression")
            ceiling = budget["approvedAbsoluteCeiling"]
            if approved and ceiling is not None and after["p95"] > ceiling:
                failures.append(f"{metric_id}: approved absolute ceiling")
        if failures:
            raise PerformanceError("performance comparison failed:\n- " + "\n- ".join(failures))
    except (OSError, KeyError, ValueError, json.JSONDecodeError, SchemaError, PerformanceError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    if args.exploratory and not approved:
        print("Exploratory comparison passed relative policy; this is not an approved Release gate.")
    else:
        print("Approved performance gate passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
