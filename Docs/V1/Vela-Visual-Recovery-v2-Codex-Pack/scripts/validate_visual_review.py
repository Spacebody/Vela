#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

from path_safety import PathSafetyError, validate_identifier
from schema_validation import load_and_validate

ROOT = Path(__file__).resolve().parents[1]

REQUIRED_CATEGORIES = {
    "structure", "alignment", "spacing", "typography",
    "controls", "stateAccuracy", "responsive",
    "lightDark", "localization",
}


def review_failures(value: dict) -> list[str]:
    failures = []
    try:
        validate_identifier(value["targetID"], "targetID")
    except PathSafetyError as error:
        failures.append(str(error))
    if not value["reviewer"].strip():
        failures.append("reviewer must not be blank")

    categories = value["categories"]
    missing = REQUIRED_CATEGORIES - categories.keys()
    if missing:
        failures.append(f"review missing categories: {sorted(missing)}")
    invalid = {
        key: categories[key]
        for key in REQUIRED_CATEGORIES & categories.keys()
        if categories[key] not in {"pass", "fail"}
    }
    if invalid:
        failures.append(f"invalid category values: {invalid}")

    if value["status"] == "approved":
        failed_categories = [
            key for key, result in categories.items() if result != "pass"
        ]
        if failed_categories:
            failures.append(f"approved review contains failures: {failed_categories}")
        if value["remainingDifferences"]:
            failures.append("approved review cannot contain remaining differences")
    elif not value["remainingDifferences"]:
        failures.append(f"{value['status']} review must describe remaining differences")
    return failures


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("review")
    parser.add_argument("--require-approved", action="store_true")
    args = parser.parse_args()

    value = load_and_validate(
        Path(args.review),
        ROOT / "schemas/visual-review.schema.json",
    )
    failures = review_failures(value)
    if failures:
        raise SystemExit("Visual review validation failed:\n- " + "\n- ".join(failures))
    if args.require_approved and value["status"] != "approved":
        raise SystemExit(f"visual review is {value['status']}, not approved")

    print(f"Visual review validation passed: {value['status']}")


if __name__ == "__main__":
    main()
