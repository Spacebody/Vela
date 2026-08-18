#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path

from schema_validation import load_and_validate, load_json
from validate_bug_registry import validate_registry
from validate_visual_review import review_failures

ROOT = Path(__file__).resolve().parents[1]


def load_matrix(path: str | None) -> dict | None:
    return load_json(Path(path)) if path is not None else None


def matrix_issues(matrix: dict | None) -> tuple[list[dict], list[str]]:
    if matrix is None:
        return [], ["visual matrix is missing"]
    results = matrix.get("results")
    if not isinstance(results, list):
        return [], ["visual matrix results must be an array"]

    issues = []
    if not results:
        issues.append("visual matrix contains zero results")
    target_ids = []
    for index, item in enumerate(results):
        if not isinstance(item, dict):
            issues.append(f"visual matrix result {index} is not an object")
            continue
        target_id = item.get("targetID")
        status = item.get("status")
        if not isinstance(target_id, str) or not target_id:
            issues.append(f"visual matrix result {index} has no targetID")
        else:
            target_ids.append(target_id)
        if status not in {"passed", "failed", "pendingTargetApproval"}:
            issues.append(f"visual matrix result {target_id or index} has invalid status")
        if status == "passed":
            metrics = item.get("metrics")
            if not isinstance(metrics, dict) or metrics.get("decision") != "pass":
                issues.append(f"visual matrix result {target_id or index} lacks a passing report")
            elif metrics.get("humanReviewRequired") is not True:
                issues.append(
                    f"visual matrix result {target_id or index} disables human review"
                )
    if len(target_ids) != len(set(target_ids)):
        issues.append("visual matrix contains duplicate targetID values")

    computed_passed = bool(results) and all(
        isinstance(item, dict) and item.get("status") == "passed"
        for item in results
    )
    if matrix.get("passed") is not computed_passed:
        issues.append("visual matrix passed flag does not match its results")
    if not computed_passed:
        issues.append("visual matrix has failed or pending results")
    return results, list(dict.fromkeys(issues))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bugs", required=True)
    parser.add_argument("--matrix")
    parser.add_argument("--reviews", nargs="*", default=[])
    parser.add_argument("--output-json", required=True)
    parser.add_argument("--output-md", required=True)
    args = parser.parse_args()

    bugs = load_and_validate(
        Path(args.bugs),
        ROOT / "schemas/bug-registry.schema.json",
    )
    validate_registry(bugs, set())
    matrix = load_matrix(args.matrix)
    visual_results, visual_matrix_issues = matrix_issues(matrix)

    reviews = []
    invalid_review_issues = []
    for path_value in args.reviews:
        review = load_and_validate(
            Path(path_value),
            ROOT / "schemas/visual-review.schema.json",
        )
        failures = review_failures(review)
        if failures:
            invalid_review_issues.extend(
                f"{review['targetID']}: {failure}" for failure in failures
            )
        reviews.append(review)

    bug_counts = Counter(
        (bug["severity"], bug["status"])
        for bug in bugs["bugs"]
    )
    unresolved_p0_p1 = [
        bug["id"] for bug in bugs["bugs"]
        if bug["severity"] in {"P0", "P1"}
        and bug["status"] not in {"verified", "notReproducible"}
    ]

    matrix_ids = [
        item["targetID"]
        for item in visual_results
        if isinstance(item, dict) and isinstance(item.get("targetID"), str)
    ]
    review_ids = [review["targetID"] for review in reviews]
    duplicate_reviews = sorted(
        target_id for target_id, count in Counter(review_ids).items() if count > 1
    )
    matrix_id_set = set(matrix_ids)
    review_id_set = set(review_ids)
    missing_reviews = sorted(matrix_id_set - review_id_set)
    unexpected_reviews = sorted(review_id_set - matrix_id_set)
    nonapproved_reviews = sorted(
        review["targetID"] for review in reviews if review["status"] != "approved"
    )
    pending_reviews = sorted(set(missing_reviews + nonapproved_reviews))
    approved_reviews = sorted(
        review["targetID"] for review in reviews if review["status"] == "approved"
    )
    review_issues = [
        *invalid_review_issues,
        *(f"missing review: {target_id}" for target_id in missing_reviews),
        *(f"unexpected review: {target_id}" for target_id in unexpected_reviews),
        *(f"duplicate review: {target_id}" for target_id in duplicate_reviews),
        *(f"review not approved: {target_id}" for target_id in nonapproved_reviews),
    ]

    summary = {
        "schemaVersion": 1,
        "bugCounts": {
            f"{severity}/{status}": count
            for (severity, status), count in sorted(bug_counts.items())
        },
        "unresolvedP0P1": unresolved_p0_p1,
        "visualResults": visual_results,
        "matrixIssues": visual_matrix_issues,
        "approvedReviews": approved_reviews,
        "pendingReviews": pending_reviews,
        "unexpectedReviews": unexpected_reviews,
        "duplicateReviews": duplicate_reviews,
        "reviewIssues": review_issues,
        "ready": (
            not unresolved_p0_p1
            and not visual_matrix_issues
            and bool(visual_results)
            and not review_issues
            and set(approved_reviews) == matrix_id_set
        ),
    }
    output_json = Path(args.output_json)
    output_md = Path(args.output_md)
    output_json.parent.mkdir(parents=True, exist_ok=True)
    output_md.parent.mkdir(parents=True, exist_ok=True)
    output_json.write_text(
        json.dumps(summary, indent=2) + "\n",
        encoding="utf-8",
    )

    lines = [
        "# Vela Visual Recovery Summary",
        "",
        f"- Ready: **{summary['ready']}**",
        f"- Unresolved P0/P1: {len(unresolved_p0_p1)}",
        f"- Visual matrix issues: {len(visual_matrix_issues)}",
        f"- Approved visual reviews: {len(approved_reviews)}",
        f"- Pending visual reviews: {len(pending_reviews)}",
        f"- Review integrity issues: {len(review_issues)}",
        "",
        "## Bug counts",
        "",
    ]
    for key, count in summary["bugCounts"].items():
        lines.append(f"- {key}: {count}")
    lines.extend(["", "## Blockers", ""])
    lines.extend(f"- {bug_id}" for bug_id in unresolved_p0_p1)
    lines.extend(f"- Matrix: {issue}" for issue in visual_matrix_issues)
    lines.extend(f"- Review: {issue}" for issue in review_issues)
    if not unresolved_p0_p1 and not visual_matrix_issues and not review_issues:
        lines.append("- None recorded")
    output_md.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(output_md)


if __name__ == "__main__":
    main()
