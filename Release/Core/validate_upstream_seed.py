#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from core_release_lib import CoreReleaseError, load_json, validate_seed


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate an immutable exact-tag Mihomo release seed")
    parser.add_argument("seed")
    args = parser.parse_args()
    try:
        seed = validate_seed(load_json(Path(args.seed), maximum=64 * 1024))
        print(f"Exact upstream seed passed: version={seed['version']} asset={seed['assetName']}")
        return 0
    except (OSError, CoreReleaseError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
