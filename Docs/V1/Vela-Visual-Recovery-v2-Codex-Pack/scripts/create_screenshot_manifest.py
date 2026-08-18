#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image

from path_safety import PathSafetyError, resolve_regular_file
from schema_validation import validate_instance
from screenshot_naming import parse_screenshot_name

ROOT = Path(__file__).resolve().parents[1]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root")
    parser.add_argument("--app-build", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    root = Path(args.root).resolve(strict=True)
    if not root.is_dir():
        raise SystemExit(f"screenshot root is not a directory: {root}")
    screenshots = []
    failures = []
    png_paths = sorted(
        path for path in root.rglob("*") if path.suffix.lower() == ".png"
    )
    for discovered in png_paths:
        relative = str(discovered.relative_to(root))
        try:
            path = resolve_regular_file(root, relative, "screenshot")
        except PathSafetyError as error:
            failures.append(str(error))
            continue
        fields = parse_screenshot_name(path.name)
        if fields is None:
            failures.append(f"illegal screenshot filename: {relative}")
            continue
        width = int(fields["width"])
        height = int(fields["height"])
        try:
            with Image.open(path) as image:
                if image.size != (width, height):
                    failures.append(
                        f"{relative}: filename size {(width, height)} != image {image.size}"
                    )
                    continue
        except OSError as error:
            failures.append(f"{relative}: invalid PNG: {error}")
            continue
        screenshots.append({
            "id": path.stem,
            "page": fields["page"],
            "state": fields["state"],
            "appearance": fields["appearance"],
            "locale": fields["locale"],
            "width": width,
            "height": height,
            "inspector": fields["inspector"],
            "path": relative,
            "sha256": sha256(path),
        })

    if failures:
        raise SystemExit("Screenshot discovery failed:\n- " + "\n- ".join(failures))
    if not screenshots:
        raise SystemExit("no screenshot filenames matched the required convention")
    ids = [item["id"] for item in screenshots]
    if len(ids) != len(set(ids)):
        raise SystemExit("duplicate screenshot ID")
    value = {
        "schemaVersion": 1,
        "appBuild": args.app_build,
        "screenshots": screenshots,
    }
    schema = json.loads(
        (ROOT / "schemas/screenshot-manifest.schema.json").read_text(encoding="utf-8")
    )
    validate_instance(value, schema, source="generated screenshot manifest")
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Wrote {len(screenshots)} screenshot entries.")


if __name__ == "__main__":
    main()
