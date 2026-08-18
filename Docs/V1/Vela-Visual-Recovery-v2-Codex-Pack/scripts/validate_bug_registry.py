#!/usr/bin/env python3
from __future__ import annotations

import argparse
from collections import Counter
from pathlib import Path

from schema_validation import load_and_validate

ROOT = Path(__file__).resolve().parents[1]


def validate_registry(data: dict, required_clear: set[str]) -> tuple[Counter, list[str]]:
    bugs = data["bugs"]
    ids = [bug["id"] for bug in bugs]
    if len(ids) != len(set(ids)):
        raise SystemExit("duplicate bug ID")

    invalid_severities = required_clear - {"P0", "P1", "P2", "P3"}
    if invalid_severities:
        raise SystemExit(f"invalid --require-clear severity: {sorted(invalid_severities)}")

    blockers = []
    counts = Counter()
    for bug in bugs:
        counts[(bug["severity"], bug["status"])] += 1
        if (
            bug["severity"] in required_clear
            and bug["status"] not in {"verified", "notReproducible"}
        ):
            blockers.append(f"{bug['id']}: {bug['severity']}/{bug['status']}")
        if bug["status"] in {"verified", "notReproducible"} and not bug["evidence"]:
            raise SystemExit(f"{bug['id']}: resolved status requires evidence")
    return counts, blockers


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("registry")
    parser.add_argument("--require-clear", default="")
    args = parser.parse_args()

    data = load_and_validate(
        Path(args.registry),
        ROOT / "schemas/bug-registry.schema.json",
    )
    required_clear = {item for item in args.require_clear.split(",") if item}
    counts, blockers = validate_registry(data, required_clear)

    for (severity, status), count in sorted(counts.items()):
        print(f"{severity}/{status}: {count}")
    if blockers:
        raise SystemExit("Bug gate failed:\n- " + "\n- ".join(blockers))
    print("Bug Registry validation passed.")


if __name__ == "__main__":
    main()
