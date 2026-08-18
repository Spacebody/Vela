#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

from PIL import Image, ImageChops, ImageEnhance

from path_safety import PathSafetyError, prepare_output_root, validate_identifier
from schema_validation import validate_instance

ROOT = Path(__file__).resolve().parents[1]


def load_rgb(path: Path) -> Image.Image:
    return Image.open(path).convert("RGB")


def load_mask(path: Path | None, size: tuple[int, int]) -> Image.Image:
    if path is None:
        return Image.new("L", size, 255)
    mask = Image.open(path).convert("L")
    if mask.size != size:
        raise ValueError(f"mask size {mask.size} != image size {size}")
    return mask


def metrics(
    target: Image.Image,
    current: Image.Image,
    mask: Image.Image,
    pixel_threshold: float,
) -> dict[str, float | int]:
    if target.size != current.size or target.size != mask.size:
        raise ValueError("target, current and mask dimensions must match")

    total = 0
    changed = 0
    absolute_sum = 0.0
    squared_sum = 0.0
    max_difference = 0.0

    target_pixels = target.get_flattened_data()
    current_pixels = current.get_flattened_data()
    mask_pixels = mask.get_flattened_data()

    for target_pixel, current_pixel, mask_value in zip(
        target_pixels,
        current_pixels,
        mask_pixels,
    ):
        if mask_value < 128:
            continue
        total += 1
        channel_differences = [
            abs(int(target_pixel[index]) - int(current_pixel[index])) / 255.0
            for index in range(3)
        ]
        pixel_max = max(channel_differences)
        pixel_mean = sum(channel_differences) / 3.0
        max_difference = max(max_difference, pixel_max)
        absolute_sum += pixel_mean
        squared_sum += sum(value * value for value in channel_differences) / 3.0
        if pixel_max > pixel_threshold:
            changed += 1

    if total == 0:
        raise ValueError("mask excludes every pixel")

    return {
        "comparedPixels": total,
        "changedPixels": changed,
        "changedPercent": changed / total * 100.0,
        "meanAbsoluteError": absolute_sum / total,
        "rmse": math.sqrt(squared_sum / total),
        "maximumDifference": max_difference,
    }


def make_diff_image(
    target: Image.Image,
    current: Image.Image,
    mask: Image.Image,
) -> Image.Image:
    difference = ImageChops.difference(target, current).convert("RGB")
    base = ImageEnhance.Brightness(target.convert("RGB")).enhance(0.24)
    output = Image.new("RGB", target.size)
    output_pixels = []
    for base_pixel, difference_pixel, mask_value in zip(
        base.get_flattened_data(),
        difference.get_flattened_data(),
        mask.get_flattened_data(),
    ):
        if mask_value < 128:
            output_pixels.append((32, 32, 32))
            continue
        intensity = max(difference_pixel)
        if intensity < 4:
            output_pixels.append(base_pixel)
        else:
            output_pixels.append(
                (
                    min(255, 80 + intensity),
                    max(0, 35 - intensity // 8),
                    max(0, 35 - intensity // 8),
                )
            )
    output.putdata(output_pixels)
    return output


def downsample(
    image: Image.Image,
    factor: int,
    resample: Image.Resampling,
) -> Image.Image:
    width = max(1, image.width // factor)
    height = max(1, image.height // factor)
    return image.resize((width, height), resample)


def write_report(output_dir: Path, report_name: str, report: dict) -> None:
    schema = json.loads(
        (ROOT / "schemas/visual-diff-report.schema.json").read_text(encoding="utf-8")
    )
    validate_instance(report, schema, source="visual diff report")
    (output_dir / report_name).write_text(
        json.dumps(report, indent=2) + "\n",
        encoding="utf-8",
    )


def markdown_code(value: str | None) -> str:
    normalized = value if value else "not provided"
    normalized = normalized.replace("\r", " ").replace("\n", " ")
    normalized = normalized.replace("`", "\\`")
    return f"`{normalized}`"


def write_review_template(
    output_dir: Path,
    *,
    report_name: str,
    target_id: str | None,
    page: str | None,
    state: str | None,
    appearance: str | None,
    locale: str | None,
    decision: str,
    reasons: list[str],
) -> None:
    reason_text = ", ".join(reasons) if reasons else "none"
    title = target_id if target_id else "unscoped-diff"
    lines = [
        f"# Visual Review: {title}",
        "",
        "> Automated visual diff is a pre-screen only. Human review is required before approval.",
        "",
        "## Context",
        "",
        f"- Target ID: {markdown_code(target_id)}",
        f"- Page: {markdown_code(page)}",
        f"- State: {markdown_code(state)}",
        f"- Appearance: {markdown_code(appearance)}",
        f"- Locale: {markdown_code(locale)}",
        f"- Automated decision: {markdown_code(decision)}",
        f"- Automated reasons: {markdown_code(reason_text)}",
        "- Human review status: `pending`",
        "",
        "## Artifacts",
        "",
        "- [Target](target.png)",
        "- [Current](current.png)",
        "- [Diff](diff.png)",
        "- [Overlay](overlay.png)",
        f"- [Metrics]({report_name})",
        "",
        "## Review Checklist",
        "",
        "- [ ] Structure - pass/reject; notes:",
        "- [ ] Alignment - pass/reject; notes:",
        "- [ ] Density - pass/reject; notes:",
        "- [ ] Typography - pass/reject; notes:",
        "- [ ] Controls - pass/reject; notes:",
        "- [ ] State accuracy - pass/reject; notes:",
        "- [ ] Responsive behavior - pass/reject; notes:",
        "",
        "## Differences",
        "",
        "### Accepted",
        "",
        "- None recorded.",
        "",
        "### Rejected",
        "",
        "- None recorded.",
        "",
        "## Human Decision",
        "",
        "- Reviewer:",
        "- Status: `pending`",
        "- Notes:",
    ]
    (output_dir / "review.md").write_text(
        "\n".join(lines) + "\n",
        encoding="utf-8",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("target")
    parser.add_argument("current")
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--mask")
    parser.add_argument("--pixel-threshold", type=float, default=0.06)
    parser.add_argument("--structural-factor", type=int, default=4)
    parser.add_argument("--max-structural-changed-percent", type=float, default=3.0)
    parser.add_argument("--max-structural-rmse", type=float, default=0.06)
    parser.add_argument("--report-name", default="report.json")
    parser.add_argument("--target-id")
    parser.add_argument("--page")
    parser.add_argument("--state")
    parser.add_argument("--appearance")
    parser.add_argument("--locale")
    args = parser.parse_args()

    target_path = Path(args.target)
    current_path = Path(args.current)
    if not 0 <= args.pixel_threshold <= 1:
        raise SystemExit("--pixel-threshold must be between 0 and 1")
    if args.structural_factor < 1:
        raise SystemExit("--structural-factor must be at least 1")
    if not 0 <= args.max_structural_changed_percent <= 100:
        raise SystemExit("--max-structural-changed-percent must be between 0 and 100")
    if not 0 <= args.max_structural_rmse <= 1:
        raise SystemExit("--max-structural-rmse must be between 0 and 1")
    try:
        validate_identifier(args.report_name, "report name")
        if args.target_id is not None:
            validate_identifier(args.target_id, "target ID")
        output_dir = prepare_output_root(Path(args.output_dir))
    except PathSafetyError as error:
        raise SystemExit(str(error)) from error

    target = load_rgb(target_path)
    current = load_rgb(current_path)
    if target.size != current.size:
        report = {
            "schemaVersion": 1,
            "target": str(target_path),
            "current": str(current_path),
            "dimensions": {
                "target": list(target.size),
                "current": list(current.size),
                "match": False,
            },
            "raw": None,
            "structural": None,
            "mask": None,
            "decision": "fail",
            "reasons": ["dimensionMismatch"],
            "humanReviewRequired": True,
        }
        write_report(output_dir, args.report_name, report)
        write_review_template(
            output_dir,
            report_name=args.report_name,
            target_id=args.target_id,
            page=args.page,
            state=args.state,
            appearance=args.appearance,
            locale=args.locale,
            decision=report["decision"],
            reasons=report["reasons"],
        )
        raise SystemExit("target and current dimensions differ")

    mask_path = Path(args.mask) if args.mask else None
    mask = load_mask(mask_path, target.size)

    raw = metrics(target, current, mask, args.pixel_threshold)

    structural_target = downsample(
        target,
        args.structural_factor,
        Image.Resampling.LANCZOS,
    )
    structural_current = downsample(
        current,
        args.structural_factor,
        Image.Resampling.LANCZOS,
    )
    structural_mask = downsample(
        mask,
        args.structural_factor,
        Image.Resampling.NEAREST,
    ).convert("L")
    structural = metrics(
        structural_target,
        structural_current,
        structural_mask,
        args.pixel_threshold,
    )

    Image.blend(target, current, 0.5).save(output_dir / "overlay.png")
    make_diff_image(target, current, mask).save(output_dir / "diff.png")
    target.save(output_dir / "target.png")
    current.save(output_dir / "current.png")
    mask.save(output_dir / "mask-used.png")

    reasons = []
    if structural["changedPercent"] > args.max_structural_changed_percent:
        reasons.append("structuralChangedPercent")
    if structural["rmse"] > args.max_structural_rmse:
        reasons.append("structuralRMSE")

    ignored_pixels = target.width * target.height - raw["comparedPixels"]
    report = {
        "schemaVersion": 1,
        "target": str(target_path),
        "current": str(current_path),
        "dimensions": {
            "target": list(target.size),
            "current": list(current.size),
            "match": True,
        },
        "raw": raw,
        "structural": {
            **structural,
            "factor": args.structural_factor,
            "size": list(structural_target.size),
        },
        "mask": {
            "path": str(mask_path) if mask_path else None,
            "ignoredPixels": ignored_pixels,
            "ignoredPercent": ignored_pixels / (target.width * target.height) * 100.0,
        },
        "thresholds": {
            "pixelThreshold": args.pixel_threshold,
            "maximumStructuralChangedPercent": args.max_structural_changed_percent,
            "maximumStructuralRMSE": args.max_structural_rmse,
        },
        "decision": "pass" if not reasons else "fail",
        "reasons": reasons,
        "humanReviewRequired": True,
    }
    write_report(output_dir, args.report_name, report)
    write_review_template(
        output_dir,
        report_name=args.report_name,
        target_id=args.target_id,
        page=args.page,
        state=args.state,
        appearance=args.appearance,
        locale=args.locale,
        decision=report["decision"],
        reasons=report["reasons"],
    )
    print(json.dumps(report, indent=2))
    if reasons:
        raise SystemExit(2)


if __name__ == "__main__":
    main()
