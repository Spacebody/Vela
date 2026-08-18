#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

from path_safety import (
    PathSafetyError,
    prepare_output_root,
    resolve_regular_file,
    validate_identifier,
)
from schema_validation import JSONSchemaValidationError, load_and_validate
from validate_visual_baseline import baseline_failures, load_validated_manifest

ROOT = Path(__file__).resolve().parents[1]


def write_summary(output_root: Path, results: list[dict]) -> dict:
    summary = {
        "schemaVersion": 1,
        "results": results,
        "passed": bool(results) and all(item["status"] == "passed" for item in results),
    }
    (output_root / "matrix-summary.json").write_text(
        json.dumps(summary, indent=2) + "\n",
        encoding="utf-8",
    )
    return summary


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest")
    parser.add_argument("--root", default=".")
    parser.add_argument("--current-root", required=True)
    parser.add_argument("--output-root", required=True)
    parser.add_argument("--only")
    parser.add_argument("--require-approved", action="store_true")
    args = parser.parse_args()

    root = Path(args.root)
    current_root = Path(args.current_root)
    output_root = prepare_output_root(Path(args.output_root))
    if args.only:
        validate_identifier(args.only, "--only targetID")

    data = load_validated_manifest(Path(args.manifest))
    manifest_failures = baseline_failures(data, root, require_approved=False)
    if manifest_failures:
        raise SystemExit(
            "Visual baseline validation failed:\n- " + "\n- ".join(manifest_failures)
        )

    results = []
    selected = [
        baseline
        for baseline in data["baselines"]
        if args.only is None or baseline["targetID"] == args.only
    ]
    if not selected:
        write_summary(output_root, results)
        raise SystemExit("Visual matrix selected zero baselines.")

    for baseline in selected:
        target_id = validate_identifier(baseline["targetID"], "targetID")
        authority = baseline["authority"]
        approval = baseline["approval"]["status"]
        if authority != "approved" or approval != "approved":
            results.append({
                "targetID": target_id,
                "status": "pendingTargetApproval",
                "authority": authority,
                "approvalStatus": approval,
            })
            print(f"{target_id}: pending target approval")
            continue

        try:
            target = resolve_regular_file(
                root,
                baseline["targetPath"],
                f"{target_id} targetPath",
            )
            current_relative = baseline.get("currentPath") or f"{target_id}.png"
            current = resolve_regular_file(
                current_root,
                current_relative,
                f"{target_id} currentPath",
            )
            output = prepare_output_root(
                output_root / target_id,
                f"{target_id} output directory",
            )
            mask_path = baseline.get("maskPath")
            mask = (
                resolve_regular_file(root, mask_path, f"{target_id} maskPath")
                if mask_path
                else None
            )
        except PathSafetyError as error:
            results.append({
                "targetID": target_id,
                "status": "failed",
                "returnCode": 1,
                "report": None,
                "review": None,
                "metrics": None,
                "validationError": str(error),
            })
            print(f"{target_id}: failed")
            continue

        thresholds = baseline.get("thresholds", {})
        command = [
            sys.executable,
            str(Path(__file__).with_name("visual_diff.py")),
            str(target),
            str(current),
            "--output-dir", str(output),
            "--target-id", target_id,
            "--page", baseline["page"],
            "--state", baseline["state"],
            "--appearance", baseline["appearance"],
            "--locale", baseline["locale"],
            "--max-structural-changed-percent",
            str(thresholds["structuralChangedPercent"]),
            "--max-structural-rmse",
            str(thresholds["structuralRMSE"]),
        ]
        if mask is not None:
            command.extend(["--mask", str(mask)])

        completed = subprocess.run(command, capture_output=True, text=True)
        report_path = output / "report.json"
        review_path = output / "review.md"
        report = None
        validation_error = None
        if report_path.is_file():
            try:
                report = load_and_validate(
                    report_path,
                    ROOT / "schemas/visual-diff-report.schema.json",
                )
            except JSONSchemaValidationError as error:
                validation_error = str(error)
        else:
            validation_error = "visual diff did not produce report.json"
        if not review_path.is_file() or not review_path.read_text(
            encoding="utf-8"
        ).strip():
            review_error = "visual diff did not produce a non-empty review.md"
            validation_error = (
                f"{validation_error}; {review_error}"
                if validation_error
                else review_error
            )

        status = (
            "passed"
            if completed.returncode == 0
            and report is not None
            and report["decision"] == "pass"
            and validation_error is None
            else "failed"
        )
        result = {
            "targetID": target_id,
            "status": status,
            "returnCode": completed.returncode,
            "report": str(report_path.relative_to(output_root)),
            "review": (
                str(review_path.relative_to(output_root))
                if review_path.is_file()
                else None
            ),
            "metrics": report,
        }
        if validation_error:
            result["validationError"] = validation_error
        results.append(result)
        print(f"{target_id}: {status}")

    summary = write_summary(output_root, results)
    blockers = [
        item for item in results
        if item["status"] == "failed"
        or (args.require_approved and item["status"] == "pendingTargetApproval")
    ]
    if blockers:
        raise SystemExit(f"Visual matrix has {len(blockers)} blocker(s).")
    if not summary["passed"]:
        print("Visual matrix completed with pending target approval(s).")
    else:
        print("Visual matrix completed.")


if __name__ == "__main__":
    main()
