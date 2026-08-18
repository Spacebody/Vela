#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

from schema_validation import load_and_validate
from validate_visual_baseline import baseline_failures, load_validated_manifest

ROOT = Path(__file__).resolve().parents[1]


def target_status_failures(status: dict, baseline: dict, repository_root: Path) -> list[str]:
    failures = baseline_failures(baseline, repository_root, require_approved=False)
    approved = [
        item
        for item in baseline["baselines"]
        if item["authority"] == "approved"
        and item["approval"]["status"] == "approved"
    ]
    approved_count = len(approved)
    if status["approvedTargetCount"] != approved_count:
        failures.append(
            "target status approvedTargetCount "
            f"{status['approvedTargetCount']} != manifest approved count {approved_count}"
        )
    if approved_count == 0 and status["status"] != "targetApprovalPending":
        failures.append(
            "zero approved targets must be reported as targetApprovalPending"
        )
    declared_pages = set(status["pages"])
    undeclared_pages = sorted(
        {item["page"] for item in baseline["baselines"]} - declared_pages
    )
    if undeclared_pages:
        failures.append(
            f"baseline manifest contains undeclared page(s): {undeclared_pages}"
        )
    return failures


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("status")
    parser.add_argument("baseline_manifest")
    parser.add_argument("--root", default=".")
    parser.add_argument("--require-approved-targets", action="store_true")
    args = parser.parse_args()

    status = load_and_validate(
        Path(args.status),
        ROOT / "schemas/target-status.schema.json",
    )
    baseline = load_validated_manifest(Path(args.baseline_manifest))
    failures = target_status_failures(status, baseline, Path(args.root))
    if failures:
        raise SystemExit("Target status validation failed:\n- " + "\n- ".join(failures))

    approved_count = status["approvedTargetCount"]
    print(f"Target status: {status['status']}")
    print(f"Approved target count: {approved_count}")
    if args.require_approved_targets and approved_count == 0:
        raise SystemExit("targetApprovalPending: no approved visual targets exist")


if __name__ == "__main__":
    main()
