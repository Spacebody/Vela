#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

from PIL import Image, ImageEnhance


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("screen_map")
    parser.add_argument("--root", default=".")
    args = parser.parse_args()

    root = Path(args.root)
    data = json.loads(Path(args.screen_map).read_text(encoding="utf-8"))
    source = Image.open(root / data["source"]).convert("RGB")

    for screen in data["screens"]:
        crop = source.crop(tuple(screen["box"]))
        original = root / screen["original"]
        structural = root / screen["structural2x"]
        original.parent.mkdir(parents=True, exist_ok=True)
        crop.save(original, optimize=True)
        upscaled = crop.resize(
            (crop.width * 2, crop.height * 2),
            Image.Resampling.LANCZOS,
        )
        upscaled = ImageEnhance.Sharpness(upscaled).enhance(1.2)
        upscaled.save(structural, optimize=True)
        print(screen["id"])


if __name__ == "__main__":
    main()
