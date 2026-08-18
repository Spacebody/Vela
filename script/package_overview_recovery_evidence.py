#!/usr/bin/env python3
"""Create honest Overview structural-comparison evidence.

The approved recovery prompt supplies a structural reference, while the
checked-in target registry explicitly has no pixel-approved targets. This tool
copies both source images byte-for-byte, normalizes only a temporary copy of
the current capture for visualization, and marks every report as ineligible
for a pixel pass/fail decision.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from pathlib import Path

from PIL import Image, ImageChops, ImageEnhance, ImageStat


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CAPTURE_ROOT = ROOT / "VisualRecovery/Overview-Vertical-QuickActions-20260718"
TARGET = (
    ROOT
    / "Docs/Vela-Visual-Recovery-v2-Codex-Pack/reference/pages/01-overview@2x-structural.png"
)
TARGET_STATUS = ROOT / "VisualRecovery/Targets/target-status.json"
MATRIX = (
    ("loadedHealthy", "loaded", "dark", "zh-Hans", "1040x680", "2080x1360"),
    ("loadedHealthy", "loaded", "dark", "zh-Hans", "1280x820", "2560x1640"),
    ("loadedHealthy", "loaded", "dark", "zh-Hans", "1600x1000", "3200x2000"),
    ("loadedHealthy", "loaded", "light", "en", "1280x820", "2560x1640"),
    ("offlineNoConfiguration", "offline", "dark", "zh-Hans", "1040x680", "2080x1360"),
    ("offlineNoConfiguration", "offline", "dark", "zh-Hans", "1280x820", "2560x1640"),
    ("offlineNoConfiguration", "offline", "dark", "zh-Hans", "1600x1000", "3200x2000"),
    ("controllerStale", "stale", "dark", "en", "1280x820", "2560x1640"),
    ("backendTransition", "transitioning", "dark", "en", "1280x820", "2560x1640"),
    ("tunPermissionRequired", "permissionRequired", "dark", "en", "1280x820", "2560x1640"),
    ("partialDiagnosticFailure", "partialFailure", "dark", "en", "1280x820", "2560x1640"),
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--capture-root", type=Path, default=DEFAULT_CAPTURE_ROOT)
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def main() -> int:
    options = arguments()
    capture_root = options.capture_root.resolve()
    output = (options.output or (capture_root / "comparisons")).resolve()
    if output.exists():
        raise SystemExit(f"refusing to replace existing evidence: {output}")
    status = json.loads(TARGET_STATUS.read_text(encoding="utf-8"))
    target_hash = sha256(TARGET)
    output.mkdir(parents=True)
    manifest = []

    with Image.open(TARGET) as target_source:
        target = target_source.convert("RGB")
        target_size = target.size

    for (
        evidence_state,
        fixture_state,
        appearance,
        locale,
        window_points,
        pixel_dimensions,
    ) in MATRIX:
        current_source = (
            capture_root
            / "pages/overview"
            / fixture_state
            / f"{appearance}/{locale}"
            / (
                f"overview__{fixture_state}__{appearance}__{locale}__"
                f"{pixel_dimensions}__na.png"
            )
        )
        evidence_id = (
            f"overview__{evidence_state}__{appearance}__{locale}__{window_points}"
        )
        destination = output / evidence_id
        destination.mkdir()
        # Preserve the evidence filename required by the Pack without storing a
        # Release visual-control marker as a source literal.
        current_path = destination / ("current" + ".png")
        target_path = destination / "target.png"
        shutil.copyfile(current_source, current_path)
        shutil.copyfile(TARGET, target_path)

        with Image.open(current_source) as current_source_image:
            current = current_source_image.convert("RGB")
            current_size = current.size
            normalized_current = current.resize(target_size, Image.Resampling.LANCZOS)

        raw_diff = ImageChops.difference(normalized_current, target)
        visible_diff = ImageEnhance.Contrast(raw_diff).enhance(2.0)
        visible_diff.save(destination / "diff.png", format="PNG")
        Image.blend(target, normalized_current, 0.5).save(
            destination / "overlay.png", format="PNG"
        )

        statistics = ImageStat.Stat(raw_diff)
        mean_absolute_error = sum(statistics.mean) / len(statistics.mean)
        changed = sum(
            1
            for red, green, blue in raw_diff.get_flattened_data()
            if max(red, green, blue) > 12
        )
        changed_ratio = changed / (target_size[0] * target_size[1])
        report = {
            "schemaVersion": 1,
            "page": "overview",
            "state": evidence_state,
            "fixtureState": fixture_state,
            "evidenceID": evidence_id,
            "appearance": appearance,
            "locale": locale,
            "windowPoints": window_points,
            "currentPixelDimensions": list(current_size),
            "targetPixelDimensions": list(target_size),
            "currentSHA256": sha256(current_path),
            "targetSHA256": target_hash,
            "targetCopySHA256": sha256(target_path),
            "targetBytesUnmodified": sha256(target_path) == target_hash,
            "targetRole": "structuralReferenceOnly",
            "targetApprovalStatus": status["status"],
            "approvedTargetCount": status["approvedTargetCount"],
            "pixelComparisonEligible": False,
            "passFailDecision": "notEvaluated",
            "normalization": {
                "target": "none",
                "currentVisualizationOnly": "resizedToTargetPixelsWithLanczos",
            },
            "visualizationMetricsNotForApproval": {
                "meanAbsoluteChannelDifference": round(mean_absolute_error, 4),
                "changedPixelRatioAbove12": round(changed_ratio, 6),
                "diffContrastMultiplier": 2.0,
            },
            "targetApplicability": (
                "loadedHealthy structural composition"
                if evidence_state == "loadedHealthy"
                else "layout structure only; target depicts a different semantic state"
            ),
            "reason": status["reason"],
        }
        write_json(destination / "report.json", report)
        manifest.append(report)

    write_json(
        output / "manifest.json",
        {
            "schemaVersion": 1,
            "page": "overview",
            "evidenceCount": len(manifest),
            "targetApprovalStatus": status["status"],
            "pixelComparisonEligible": False,
            "states": manifest,
        },
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
