#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path

from PIL import Image

from path_safety import PathSafetyError, resolve_regular_file
from schema_validation import load_and_validate
from screenshot_naming import parse_screenshot_name

ROOT = Path(__file__).resolve().parents[1]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest")
    parser.add_argument("--root", required=True)
    args = parser.parse_args()

    data = load_and_validate(
        Path(args.manifest),
        ROOT / "schemas/screenshot-manifest.schema.json",
    )
    root = Path(args.root).resolve(strict=True)
    if not root.is_dir():
        raise SystemExit(f"screenshot root is not a directory: {root}")
    ids = []
    failures = []
    registered_paths = set()

    for item in data["screenshots"]:
        ids.append(item["id"])
        try:
            path = resolve_regular_file(root, item["path"], f"{item['id']} path")
        except PathSafetyError as error:
            failures.append(str(error))
            continue
        relative = str(path.relative_to(root))
        registered_paths.add(relative)
        fields = parse_screenshot_name(path.name)
        if fields is None:
            failures.append(f"{item['id']}: illegal screenshot filename")
        else:
            expected = {
                "id": path.stem,
                "page": fields["page"],
                "state": fields["state"],
                "appearance": fields["appearance"],
                "locale": fields["locale"],
                "width": int(fields["width"]),
                "height": int(fields["height"]),
                "inspector": fields["inspector"],
            }
            for key, value in expected.items():
                if item[key] != value:
                    failures.append(
                        f"{item['id']}: manifest {key} {item[key]!r} != filename {value!r}"
                    )
        try:
            with Image.open(path) as image:
                if image.size != (item["width"], item["height"]):
                    failures.append(f"{item['id']}: dimensions differ")
        except OSError as error:
            failures.append(f"{item['id']}: invalid PNG: {error}")
        if sha256(path) != item["sha256"]:
            failures.append(f"{item['id']}: SHA differs")

    if len(ids) != len(set(ids)):
        failures.append("duplicate screenshot ID")

    discovered_paths = set()
    for discovered in sorted(
        path for path in root.rglob("*") if path.suffix.lower() == ".png"
    ):
        relative = str(discovered.relative_to(root))
        try:
            resolve_regular_file(root, relative, "discovered screenshot")
        except PathSafetyError as error:
            failures.append(str(error))
            continue
        if parse_screenshot_name(discovered.name) is None:
            failures.append(f"illegal screenshot filename: {relative}")
            continue
        discovered_paths.add(relative)
    missing_entries = sorted(discovered_paths - registered_paths)
    stale_entries = sorted(registered_paths - discovered_paths)
    failures.extend(f"unregistered screenshot: {path}" for path in missing_entries)
    failures.extend(f"manifest path was not discovered: {path}" for path in stale_entries)

    if failures:
        raise SystemExit("Screenshot manifest failed:\n- " + "\n- ".join(failures))
    print(f"Validated {len(ids)} screenshot(s).")


if __name__ == "__main__":
    main()
