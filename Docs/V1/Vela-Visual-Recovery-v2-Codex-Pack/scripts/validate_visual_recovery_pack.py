#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable, Iterator

ROOT = Path(__file__).resolve().parents[1]
PACK_GENERATED = ROOT / "generated"
GENERATED = PACK_GENERATED
PYTHON = sys.executable
BASH = "/bin/bash"


def isolated_validation_requested() -> bool:
    return os.environ.get("VELA_PACK_VALIDATION_ISOLATED") == "1"


def is_within(path: Path, directory: Path) -> bool:
    try:
        path.resolve().relative_to(directory.resolve())
    except ValueError:
        return False
    return True


def isolated_temporary_parent() -> Path:
    # Do not trust TMPDIR: callers may point it at the pack being validated.
    candidates = (Path("/tmp"), Path("/var/tmp"), Path.home())
    for candidate in candidates:
        resolved = candidate.resolve()
        if resolved.is_dir() and not is_within(resolved, ROOT):
            return resolved
    raise SystemExit("no temporary directory outside the source pack is available")


@contextmanager
def generated_workspace() -> Iterator[Path]:
    """Provide scratch space without polluting the source pack in isolated mode."""

    global GENERATED

    previous = GENERATED
    if isolated_validation_requested():
        with tempfile.TemporaryDirectory(
            prefix="vela-visual-recovery-validation-",
            dir=isolated_temporary_parent(),
        ) as temporary:
            GENERATED = Path(temporary) / "generated"
            if is_within(GENERATED, ROOT):
                raise SystemExit("isolated validation workspace resolved inside source pack")
            GENERATED.mkdir()
            try:
                yield GENERATED
            finally:
                GENERATED = previous
        return

    GENERATED = PACK_GENERATED
    if GENERATED.exists():
        shutil.rmtree(GENERATED)
    GENERATED.mkdir()
    try:
        yield GENERATED
    finally:
        GENERATED = previous


def run(*args: str, expect_success: bool = True) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    if isolated_validation_requested():
        if is_within(GENERATED, ROOT):
            raise SystemExit("isolated subprocess workspace resolved inside source pack")
        for variable in ("TMPDIR", "TMP", "TEMP"):
            environment[variable] = str(GENERATED)
        environment["PYTHONDONTWRITEBYTECODE"] = "1"

    result = subprocess.run(
        list(args),
        capture_output=True,
        text=True,
        env=environment,
    )
    if expect_success and result.returncode != 0:
        print(result.stdout)
        print(result.stderr, file=sys.stderr)
        raise SystemExit(f"command failed: {' '.join(args)}")
    if not expect_success and result.returncode == 0:
        raise SystemExit(f"negative test unexpectedly passed: {' '.join(args)}")
    return result


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def assert_json(
    path: Path,
    predicate: Callable[[Any], bool],
    message: str,
) -> Any:
    value = load_json(path)
    if not predicate(value):
        raise SystemExit(f"{message}: {path}")
    return value


def schema_validate(schema: str, *instances: Path, expect_success: bool = True) -> None:
    run(
        PYTHON,
        str(ROOT / "scripts/validate_json_schema.py"),
        str(ROOT / f"schemas/{schema}"),
        *(str(path) for path in instances),
        expect_success=expect_success,
    )


def validate_required_files() -> None:
    required = [
        "README.md",
        "01-CODEX-MASTER-PROMPT.md",
        "10-FIXTURE-SCREENSHOT-MODE.md",
        "11-VISUAL-DIFF-PIPELINE.md",
        "23-IMPLEMENTATION-GATES.md",
        "25-ACCEPTANCE-CHECKLIST.md",
        "27-FINAL-REVIEW-PROMPT.md",
        "reference/00-full-visual-poster.png",
        "scripts/path_safety.py",
        "scripts/release-visual-test-markers.txt",
        "scripts/schema_validation.py",
        "scripts/screenshot_naming.py",
        "scripts/validate_json_documents.py",
        "scripts/validate_json_schema.py",
        "scripts/validate_target_status.py",
        "schemas/bug-registry.schema.json",
        "schemas/fixture-registry.schema.json",
        "schemas/page-contract.schema.json",
        "schemas/screenshot-manifest.schema.json",
        "schemas/target-status.schema.json",
        "schemas/visual-baseline-manifest.schema.json",
        "schemas/visual-diff-report.schema.json",
        "schemas/visual-review.schema.json",
        "fixtures/review-template.expected.md",
    ]
    for relative in required:
        path = ROOT / relative
        if not path.is_file() or path.stat().st_size == 0:
            raise SystemExit(f"missing or empty: {relative}")


def validate_schema_fixtures() -> None:
    schema_validate(
        "bug-registry.schema.json",
        ROOT / "fixtures/bug-registry.example.json",
        ROOT / "fixtures/bug-registry-clear.json",
    )
    schema_validate(
        "fixture-registry.schema.json",
        ROOT / "fixtures/fixture-registry.example.json",
    )
    schema_validate(
        "page-contract.schema.json",
        ROOT / "fixtures/page-contract.example.json",
    )
    schema_validate(
        "visual-baseline-manifest.schema.json",
        ROOT / "fixtures/visual-baseline-manifest.example.json",
        ROOT / "fixtures/visual-baseline-test-empty.json",
        ROOT / "fixtures/visual-baseline-test-pass.json",
        ROOT / "fixtures/visual-baseline-test-fail.json",
        ROOT / "fixtures/visual-baseline-test-pending.json",
        ROOT / "fixtures/visual-baseline-test-traversal.json",
    )
    schema_validate(
        "target-status.schema.json",
        ROOT / "fixtures/target-status-pending.json",
    )
    schema_validate(
        "visual-review.schema.json",
        ROOT / "fixtures/visual-review-approved.json",
        ROOT / "fixtures/visual-review-failed.json",
        ROOT / "fixtures/visual-review-mismatched.json",
    )

    invalid_review = GENERATED / "schema-negative/invalid-review.json"
    write_json(
        invalid_review,
        {
            "schemaVersion": 1,
            "targetID": "sample.pass",
            "reviewer": "Design Owner",
            "status": "approved",
            "categories": {"structure": "pass"},
            "remainingDifferences": [],
        },
    )
    schema_validate(
        "visual-review.schema.json",
        invalid_review,
        expect_success=False,
    )

    invalid_bug = GENERATED / "schema-negative/invalid-bug.json"
    write_json(
        invalid_bug,
        {
            "schemaVersion": 1,
            "bugs": [
                {
                    "id": "BUG-INVALID",
                    "severity": "P9",
                    "status": "done",
                    "title": "unsupported enum values",
                    "evidence": [],
                    "allowedPaths": [],
                }
            ],
        },
    )
    schema_validate(
        "bug-registry.schema.json",
        invalid_bug,
        expect_success=False,
    )

    missing_approval_metadata = GENERATED / "schema-negative/missing-approval.json"
    value = load_json(ROOT / "fixtures/visual-baseline-test-pass.json")
    del value["baselines"][0]["approval"]["approvedBy"]
    del value["baselines"][0]["approval"]["approvedAt"]
    write_json(missing_approval_metadata, value)
    schema_validate(
        "visual-baseline-manifest.schema.json",
        missing_approval_metadata,
        expect_success=False,
    )

    invalid_baseline_capture_metadata = (
        GENERATED / "schema-negative/invalid-baseline-capture-metadata.json"
    )
    value = load_json(ROOT / "fixtures/visual-baseline-test-pass.json")
    value["baselines"][0]["sha256"] = "A" * 64
    value["baselines"][0]["inspector"] = "hidden"
    value["baselines"][0]["captureBoundary"] = "popover"
    write_json(invalid_baseline_capture_metadata, value)
    schema_validate(
        "visual-baseline-manifest.schema.json",
        invalid_baseline_capture_metadata,
        expect_success=False,
    )

    missing_baseline_capture_metadata = (
        GENERATED / "schema-negative/missing-baseline-capture-metadata.json"
    )
    value = load_json(ROOT / "fixtures/visual-baseline-test-pass.json")
    for key in ("sha256", "inspector", "captureBoundary"):
        del value["baselines"][0][key]
    write_json(missing_baseline_capture_metadata, value)
    schema_validate(
        "visual-baseline-manifest.schema.json",
        missing_baseline_capture_metadata,
        expect_success=False,
    )

    unsupported_schema = GENERATED / "schema-negative/unsupported-keyword.schema.json"
    empty_instance = GENERATED / "schema-negative/empty-instance.json"
    write_json(
        unsupported_schema,
        {
            "type": "object",
            "properties": {
                "optional": {"type": "string", "unsupportedAssertion": 1}
            },
        },
    )
    write_json(empty_instance, {})
    run(
        PYTHON,
        str(ROOT / "scripts/validate_json_schema.py"),
        str(unsupported_schema),
        str(empty_instance),
        expect_success=False,
    )


def validate_baselines_and_matrix() -> tuple[Path, Path]:
    validator = str(ROOT / "scripts/validate_visual_baseline.py")
    common = ("--root", str(ROOT))
    run(
        PYTHON,
        validator,
        str(ROOT / "fixtures/visual-baseline-test-pass.json"),
        *common,
        "--require-approved",
    )
    run(
        PYTHON,
        validator,
        str(ROOT / "fixtures/visual-baseline-test-empty.json"),
        *common,
    )
    run(
        PYTHON,
        validator,
        str(ROOT / "fixtures/visual-baseline-test-empty.json"),
        *common,
        "--require-approved",
        expect_success=False,
    )
    run(
        PYTHON,
        validator,
        str(ROOT / "fixtures/visual-baseline-test-pending.json"),
        *common,
    )
    run(
        PYTHON,
        validator,
        str(ROOT / "fixtures/visual-baseline-test-pending.json"),
        *common,
        "--require-approved",
        expect_success=False,
    )

    target_status_validator = str(ROOT / "scripts/validate_target_status.py")
    run(
        PYTHON,
        target_status_validator,
        str(ROOT / "fixtures/target-status-pending.json"),
        str(ROOT / "fixtures/visual-baseline-test-empty.json"),
        "--root",
        str(ROOT),
    )
    run(
        PYTHON,
        target_status_validator,
        str(ROOT / "fixtures/target-status-pending.json"),
        str(ROOT / "fixtures/visual-baseline-test-empty.json"),
        "--root",
        str(ROOT),
        "--require-approved-targets",
        expect_success=False,
    )

    blank_approver = GENERATED / "baseline-blank-approver.json"
    blank_approver_value = load_json(
        ROOT / "fixtures/visual-baseline-test-pass.json"
    )
    blank_approver_value["baselines"][0]["approval"]["approvedBy"] = "   "
    write_json(blank_approver, blank_approver_value)
    run(
        PYTHON,
        validator,
        str(blank_approver),
        *common,
        "--require-approved",
        expect_success=False,
    )
    wrong_sha256 = GENERATED / "baseline-wrong-sha256.json"
    wrong_sha256_value = load_json(
        ROOT / "fixtures/visual-baseline-test-pass.json"
    )
    wrong_sha256_value["baselines"][0]["sha256"] = "0" * 64
    write_json(wrong_sha256, wrong_sha256_value)
    run(
        PYTHON,
        validator,
        str(wrong_sha256),
        *common,
        "--require-approved",
        expect_success=False,
    )
    run(
        PYTHON,
        validator,
        str(ROOT / "fixtures/visual-baseline-test-traversal.json"),
        *common,
        expect_success=False,
    )

    symlink_dir = GENERATED / "symlink-negative"
    symlink_dir.mkdir(parents=True)
    symlink_target = symlink_dir / "linked-target.png"
    symlink_target.symlink_to(ROOT / "fixtures/images/target.png")
    symlink_manifest = symlink_dir / "baseline.json"
    write_json(
        symlink_manifest,
        {
            "schemaVersion": 1,
            "baselines": [
                {
                    "targetID": "sample.symlink",
                    "page": "sample",
                    "state": "loaded",
                    "appearance": "dark",
                    "locale": "en",
                    "width": 320,
                    "height": 200,
                    "inspector": "na",
                    "captureBoundary": "mainWindow",
                    "sha256": "7731ac88c35f7c5d540e1d673650d478cddac99dfb783a75b6c4bc6a846a0b08",
                    "targetPath": "linked-target.png",
                    "currentPath": "current-pass.png",
                    "maskPath": None,
                    "authority": "approved",
                    "approval": {
                        "status": "approved",
                        "approvedBy": "Security Test",
                        "approvedAt": "2026-07-14T00:00:00Z",
                    },
                    "thresholds": {
                        "structuralChangedPercent": 0.1,
                        "structuralRMSE": 0.001,
                    },
                }
            ],
        },
    )
    run(
        PYTHON,
        validator,
        str(symlink_manifest),
        "--root",
        str(symlink_dir),
        "--require-approved",
        expect_success=False,
    )

    matrix = str(ROOT / "scripts/run_visual_matrix.py")
    matrix_pass = GENERATED / "matrix-pass"
    run(
        PYTHON,
        matrix,
        str(ROOT / "fixtures/visual-baseline-test-pass.json"),
        "--root",
        str(ROOT),
        "--current-root",
        str(ROOT / "fixtures/images"),
        "--output-root",
        str(matrix_pass),
        "--require-approved",
    )
    assert_json(
        matrix_pass / "matrix-summary.json",
        lambda value: value.get("passed") is True
        and [
            (item.get("targetID"), item.get("review"))
            for item in value.get("results", [])
        ] == [("sample.pass", "sample.pass/review.md")],
        "passing matrix summary is inconsistent",
    )
    generated_review = matrix_pass / "sample.pass/review.md"
    expected_review = ROOT / "fixtures/review-template.expected.md"
    if not generated_review.is_file():
        raise SystemExit("passing matrix did not produce per-target review.md")
    if generated_review.read_text(encoding="utf-8") != expected_review.read_text(
        encoding="utf-8"
    ):
        raise SystemExit("generated review.md does not match deterministic fixture")

    matrix_fail = GENERATED / "matrix-fail"
    run(
        PYTHON,
        matrix,
        str(ROOT / "fixtures/visual-baseline-test-fail.json"),
        "--root",
        str(ROOT),
        "--current-root",
        str(ROOT / "fixtures/images"),
        "--output-root",
        str(matrix_fail),
        "--require-approved",
        expect_success=False,
    )
    assert_json(
        matrix_fail / "matrix-summary.json",
        lambda value: value.get("passed") is False
        and len(value.get("results", [])) == 1
        and value["results"][0].get("status") == "failed"
        and value["results"][0].get("review") == "sample.fail/review.md",
        "failing matrix did not retain its per-target review template",
    )

    matrix_pending = GENERATED / "matrix-pending"
    run(
        PYTHON,
        matrix,
        str(ROOT / "fixtures/visual-baseline-test-pending.json"),
        "--root",
        str(ROOT),
        "--current-root",
        str(ROOT / "fixtures/images"),
        "--output-root",
        str(matrix_pending),
    )
    assert_json(
        matrix_pending / "matrix-summary.json",
        lambda value: value.get("passed") is False
        and [item.get("status") for item in value.get("results", [])]
        == ["pendingTargetApproval"],
        "pending target was not reported truthfully",
    )
    run(
        PYTHON,
        matrix,
        str(ROOT / "fixtures/visual-baseline-test-pending.json"),
        "--root",
        str(ROOT),
        "--current-root",
        str(ROOT / "fixtures/images"),
        "--output-root",
        str(GENERATED / "matrix-pending-required"),
        "--require-approved",
        expect_success=False,
    )
    empty_selection = GENERATED / "matrix-empty-selection"
    run(
        PYTHON,
        matrix,
        str(ROOT / "fixtures/visual-baseline-test-pass.json"),
        "--root",
        str(ROOT),
        "--current-root",
        str(ROOT / "fixtures/images"),
        "--output-root",
        str(empty_selection),
        "--only",
        "sample.not-present",
        expect_success=False,
    )
    assert_json(
        empty_selection / "matrix-summary.json",
        lambda value: value.get("passed") is False and value.get("results") == [],
        "empty matrix selection was not recorded as failed",
    )
    run(
        PYTHON,
        matrix,
        str(ROOT / "fixtures/visual-baseline-test-empty.json"),
        "--root",
        str(ROOT),
        "--current-root",
        str(ROOT / "fixtures/images"),
        "--output-root",
        str(GENERATED / "matrix-empty"),
        expect_success=False,
    )
    run(
        PYTHON,
        matrix,
        str(ROOT / "fixtures/visual-baseline-test-traversal.json"),
        "--root",
        str(ROOT),
        "--current-root",
        str(ROOT / "fixtures/images"),
        "--output-root",
        str(GENERATED / "matrix-traversal"),
        expect_success=False,
    )
    return matrix_pass, matrix_pending


def validate_visual_diffs() -> None:
    visual_diff = str(ROOT / "scripts/visual_diff.py")
    target = str(ROOT / "fixtures/images/target.png")
    pass_output = GENERATED / "diff-pass"
    run(
        PYTHON,
        visual_diff,
        target,
        str(ROOT / "fixtures/images/current-pass.png"),
        "--output-dir",
        str(pass_output),
        "--max-structural-changed-percent",
        "0.1",
        "--max-structural-rmse",
        "0.001",
    )

    fail_output = GENERATED / "diff-fail"
    run(
        PYTHON,
        visual_diff,
        target,
        str(ROOT / "fixtures/images/current-fail.png"),
        "--output-dir",
        str(fail_output),
        "--max-structural-changed-percent",
        "0.1",
        "--max-structural-rmse",
        "0.001",
        expect_success=False,
    )

    mismatch_output = GENERATED / "diff-dimension-mismatch"
    run(
        PYTHON,
        visual_diff,
        target,
        str(ROOT / "reference/pages/01-overview.png"),
        "--output-dir",
        str(mismatch_output),
        expect_success=False,
    )
    for output in (pass_output, fail_output, mismatch_output):
        report = output / "report.json"
        if not report.is_file():
            raise SystemExit(f"visual diff did not write report: {output}")
        schema_validate("visual-diff-report.schema.json", report)
        review = output / "review.md"
        if not review.is_file():
            raise SystemExit(f"visual diff did not write review template: {output}")
        review_text = review.read_text(encoding="utf-8")
        required_review_sections = (
            "## Context",
            "## Artifacts",
            "## Review Checklist",
            "### Accepted",
            "### Rejected",
            "## Human Decision",
            "- Status: `pending`",
        )
        missing_sections = [
            section for section in required_review_sections
            if section not in review_text
        ]
        if missing_sections:
            raise SystemExit(
                f"visual review template is incomplete for {output}: "
                + ", ".join(missing_sections)
            )
    assert_json(
        mismatch_output / "report.json",
        lambda value: value.get("decision") == "fail"
        and value.get("raw") is None
        and value.get("structural") is None,
        "dimension mismatch report is not schema-compliant fail-closed output",
    )


def validate_bug_review_and_paths() -> None:
    run(
        PYTHON,
        str(ROOT / "scripts/validate_bug_registry.py"),
        str(ROOT / "fixtures/bug-registry.example.json"),
    )
    run(
        PYTHON,
        str(ROOT / "scripts/validate_bug_registry.py"),
        str(ROOT / "fixtures/bug-registry.example.json"),
        "--require-clear",
        "P0,P1",
        expect_success=False,
    )

    review_validator = str(ROOT / "scripts/validate_visual_review.py")
    run(
        PYTHON,
        review_validator,
        str(ROOT / "fixtures/visual-review-approved.json"),
        "--require-approved",
    )
    run(
        PYTHON,
        review_validator,
        str(ROOT / "fixtures/visual-review-failed.json"),
        "--require-approved",
        expect_success=False,
    )

    contract = ROOT / "fixtures/page-contract.example.json"
    changed_paths = str(ROOT / "scripts/validate_changed_paths.py")
    run(
        PYTHON,
        changed_paths,
        str(contract),
        "--paths-file",
        str(ROOT / "fixtures/changed-paths-pass.txt"),
    )
    run(
        PYTHON,
        changed_paths,
        str(contract),
        "--paths-file",
        str(ROOT / "fixtures/changed-paths-fail.txt"),
        expect_success=False,
    )


def validate_screenshots() -> None:
    screenshot_manifest = GENERATED / "screenshot-manifest.json"
    creator = str(ROOT / "scripts/create_screenshot_manifest.py")
    validator = str(ROOT / "scripts/validate_screenshot_manifest.py")
    run(
        PYTHON,
        creator,
        str(ROOT / "fixtures/screenshots"),
        "--app-build",
        "fixture",
        "--output",
        str(screenshot_manifest),
    )
    schema_validate("screenshot-manifest.schema.json", screenshot_manifest)
    run(
        PYTHON,
        validator,
        str(screenshot_manifest),
        "--root",
        str(ROOT / "fixtures/screenshots"),
    )

    illegal_root = GENERATED / "screenshot-illegal"
    illegal_root.mkdir(parents=True)
    valid_source = next((ROOT / "fixtures/screenshots").glob("*.png"))
    shutil.copy2(valid_source, illegal_root / valid_source.name)
    shutil.copy2(valid_source, illegal_root / "not-a-legal-screenshot-name.PNG")
    run(
        PYTHON,
        creator,
        str(illegal_root),
        "--app-build",
        "fixture",
        "--output",
        str(GENERATED / "illegal-screenshot-manifest.json"),
        expect_success=False,
    )

    unregistered_root = GENERATED / "screenshot-unregistered"
    unregistered_root.mkdir(parents=True)
    first = illegal_root / valid_source.name
    second_source = next(
        path
        for path in (ROOT / "fixtures/screenshots").glob("*.png")
        if path.name != valid_source.name
    )
    shutil.copy2(first, unregistered_root / first.name)
    partial_manifest = GENERATED / "partial-screenshot-manifest.json"
    run(
        PYTHON,
        creator,
        str(unregistered_root),
        "--app-build",
        "fixture",
        "--output",
        str(partial_manifest),
    )
    shutil.copy2(second_source, unregistered_root / second_source.name)
    run(
        PYTHON,
        validator,
        str(partial_manifest),
        "--root",
        str(unregistered_root),
        expect_success=False,
    )


def validate_summaries(matrix_pass: Path) -> None:
    generator = str(ROOT / "scripts/generate_visual_summary.py")
    blocked_json = GENERATED / "summary-blocked.json"
    run(
        PYTHON,
        generator,
        "--bugs",
        str(ROOT / "fixtures/bug-registry.example.json"),
        "--matrix",
        str(matrix_pass / "matrix-summary.json"),
        "--reviews",
        str(ROOT / "fixtures/visual-review-approved.json"),
        "--output-json",
        str(blocked_json),
        "--output-md",
        str(GENERATED / "summary-blocked.md"),
    )
    assert_json(
        blocked_json,
        lambda value: value.get("ready") is False and bool(value.get("unresolvedP0P1")),
        "summary ignored unresolved P0/P1 bugs",
    )

    ready_json = GENERATED / "summary-ready.json"
    run(
        PYTHON,
        generator,
        "--bugs",
        str(ROOT / "fixtures/bug-registry-clear.json"),
        "--matrix",
        str(matrix_pass / "matrix-summary.json"),
        "--reviews",
        str(ROOT / "fixtures/visual-review-approved.json"),
        "--output-json",
        str(ready_json),
        "--output-md",
        str(GENERATED / "summary-ready.md"),
    )
    assert_json(
        ready_json,
        lambda value: value.get("ready") is True,
        "complete matching evidence did not produce a ready summary",
    )

    mismatch_json = GENERATED / "summary-review-mismatch.json"
    run(
        PYTHON,
        generator,
        "--bugs",
        str(ROOT / "fixtures/bug-registry-clear.json"),
        "--matrix",
        str(matrix_pass / "matrix-summary.json"),
        "--reviews",
        str(ROOT / "fixtures/visual-review-mismatched.json"),
        "--output-json",
        str(mismatch_json),
        "--output-md",
        str(GENERATED / "summary-review-mismatch.md"),
    )
    assert_json(
        mismatch_json,
        lambda value: value.get("ready") is False
        and value.get("unexpectedReviews") == ["different-target"]
        and value.get("pendingReviews") == ["sample.pass"],
        "mismatched visual review was accepted",
    )

    empty_matrix = GENERATED / "matrix-empty-summary.json"
    write_json(empty_matrix, {"schemaVersion": 1, "results": [], "passed": False})
    empty_json = GENERATED / "summary-empty-matrix.json"
    run(
        PYTHON,
        generator,
        "--bugs",
        str(ROOT / "fixtures/bug-registry-clear.json"),
        "--matrix",
        str(empty_matrix),
        "--output-json",
        str(empty_json),
        "--output-md",
        str(GENERATED / "summary-empty-matrix.md"),
    )
    assert_json(
        empty_json,
        lambda value: value.get("ready") is False
        and "visual matrix contains zero results" in value.get("matrixIssues", []),
        "empty visual matrix was accepted",
    )


def validate_release_scanner() -> None:
    scanner = str(ROOT / "scripts/scan_release_visual_test_controls.sh")
    clean_source = GENERATED / "release-clean"
    (clean_source / "Sources").mkdir(parents=True)
    (clean_source / "Sources/App.swift").write_text(
        'let productionValue = "Vela"\n',
        encoding="utf-8",
    )
    run(BASH, scanner, str(clean_source))

    markers = [
        line.strip()
        for line in (ROOT / "scripts/release-visual-test-markers.txt")
        .read_text(encoding="utf-8")
        .splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    if not markers:
        raise SystemExit("release marker registry is empty")
    for index, marker in enumerate(markers):
        bad_source = GENERATED / f"release-bad-{index:02d}"
        (bad_source / "Sources").mkdir(parents=True)
        (bad_source / "Sources/App.swift").write_text(
            f"// forbidden visual-test marker\nlet marker = {marker!r}\n",
            encoding="utf-8",
        )
        run(BASH, scanner, str(bad_source), expect_success=False)

    excluded_source = GENERATED / "release-excluded-build"
    (excluded_source / "Sources").mkdir(parents=True)
    (excluded_source / ".build").mkdir(parents=True)
    (excluded_source / "Sources/App.swift").write_text(
        'let productionValue = "Vela"\n',
        encoding="utf-8",
    )
    (excluded_source / ".build/Generated.swift").write_text(
        f"let testOnly = {markers[0]!r}\n",
        encoding="utf-8",
    )
    run(BASH, scanner, str(excluded_source))

    app_bundle = GENERATED / "Vela.app"
    binary = app_bundle / "Contents/MacOS/Vela"
    binary.parent.mkdir(parents=True)
    binary.write_text(
        f"#!/bin/sh\n# embedded forbidden marker: {markers[-1]}\nexit 0\n",
        encoding="utf-8",
    )
    binary.chmod(0o755)
    run(BASH, scanner, str(clean_source), str(app_bundle), expect_success=False)


def validate_package_invariants() -> None:
    package = load_json(ROOT / "manifest.json")
    if package["target"]["architectures"] != ["arm64"]:
        raise SystemExit("architecture must remain arm64 only")
    if package["referenceAuthority"]["finalAcceptance"] != (
        "approved per-page targets plus human review"
    ):
        raise SystemExit("final target authority policy changed")


def main() -> None:
    with generated_workspace():
        validate_required_files()
        json_documents = sorted(
            path
            for path in ROOT.rglob("*.json")
            if PACK_GENERATED not in path.parents
        )
        run(
            PYTHON,
            str(ROOT / "scripts/validate_json_documents.py"),
            *(str(path) for path in json_documents),
        )
        validate_schema_fixtures()
        validate_visual_diffs()
        matrix_pass, _matrix_pending = validate_baselines_and_matrix()
        validate_bug_review_and_paths()
        validate_screenshots()
        validate_summaries(matrix_pass)
        validate_release_scanner()
        validate_package_invariants()

    print("Vela Visual Recovery v2 pack validation passed.")


if __name__ == "__main__":
    main()
